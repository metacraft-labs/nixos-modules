#!/usr/bin/env python3
"""
Fetch macOS InstallAssistant.pkg from Apple's Software Update Catalog

This script parses Apple's software update catalog to find the latest
InstallAssistant.pkg for a specified macOS version, then downloads it.

Usage:
    ./fetch-installassistant.py --version 14  # Download Sonoma (14.x)
    ./fetch-installassistant.py --version 13  # Download Ventura (13.x)
    ./fetch-installassistant.py --list        # List available versions

References:
- Apple Software Update Catalog: https://swscan.apple.com/content/catalogs/others/
- Similar approach to mist-cli and fetch-macOS-v2.py
"""

import argparse
import plistlib
import ssl
import sys
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional, Tuple

# Create SSL context that uses system certificates
# In Nix sandbox, we need to explicitly use system CA bundle
try:
    import certifi
    ssl_context = ssl.create_default_context(cafile=certifi.where())
except ImportError:
    # Fall back to default context if certifi not available
    ssl_context = ssl._create_unverified_context()

# Apple's software update catalog URL
CATALOG_URL = "https://swscan.apple.com/content/catalogs/others/index-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"

# macOS version names
VERSION_NAMES = {
    11: "Big Sur",
    12: "Monterey",
    13: "Ventura",
    14: "Sonoma",
    15: "Sequoia",
    16: "Tahoe",
}


def fetch_catalog() -> dict:
    """Download and parse Apple's software update catalog."""
    print("Fetching Apple software update catalog...", file=sys.stderr)
    try:
        with urllib.request.urlopen(CATALOG_URL, context=ssl_context) as response:
            data = response.read()
            catalog = plistlib.loads(data)
        print(f"Catalog loaded: {len(catalog['Products'])} products", file=sys.stderr)
        return catalog
    except urllib.error.URLError as e:
        print(f"Error fetching catalog: {e}", file=sys.stderr)
        sys.exit(1)


def find_installassistant_products(catalog: dict) -> list:
    """
    Find all products in the catalog that contain InstallAssistant.pkg.

    Returns a list of (product_key, post_date, url, distributions) tuples.
    """
    products = []

    for prod_key, prod in catalog['Products'].items():
        post_date = prod.get('PostDate')
        if not post_date:
            continue

        packages = prod.get('Packages', [])
        for pkg in packages:
            url = pkg.get('URL', '')
            if 'InstallAssistant.pkg' in url and not 'InstallAssistantAuto' in url:
                distributions = prod.get('Distributions', {})
                products.append((prod_key, post_date, url, distributions))
                break  # Only need one InstallAssistant per product

    # Sort by date (most recent first)
    products.sort(key=lambda x: x[1], reverse=True)
    return products


def get_version_from_distribution(dist_url: str) -> Optional[Tuple[int, str]]:
    """
    Fetch the distribution file and extract macOS version.

    Returns (major_version, full_version_string) or None if failed.
    """
    try:
        with urllib.request.urlopen(dist_url, context=ssl_context) as response:
            content = response.read().decode('utf-8')

        # Parse version from distribution XML
        # Look for versStr="X.Y.Z" or <title>macOS NAME</title>
        import re

        # Extract version string (e.g., "14.8.3")
        vers_match = re.search(r'versStr="([0-9.]+)"', content)
        if vers_match:
            version_str = vers_match.group(1)
            major = int(version_str.split('.')[0])
            return (major, version_str)

        # Fallback: try to extract from title
        title_match = re.search(r'<title>macOS ([^<]+)</title>', content)
        if title_match:
            name = title_match.group(1)
            # Try to map name to version
            for ver, ver_name in VERSION_NAMES.items():
                if ver_name in name:
                    return (ver, f"{ver}.x")

        return None
    except Exception as e:
        print(f"Warning: Failed to fetch distribution {dist_url}: {e}", file=sys.stderr)
        return None


def list_available_versions(catalog: dict):
    """List all available macOS versions with InstallAssistant."""
    products = find_installassistant_products(catalog)

    print("\nAvailable macOS versions with InstallAssistant.pkg:\n")
    print(f"{'Date':<12} {'Version':<15} {'Product Key':<15} {'Name':<15}")
    print("-" * 60)

    seen_versions = set()
    for prod_key, post_date, url, distributions in products[:20]:  # Show top 20
        dist_url = distributions.get('English', '')
        if not dist_url:
            continue

        version_info = get_version_from_distribution(dist_url)
        if version_info:
            major, version_str = version_info
            # Only show each major version once
            if major not in seen_versions:
                seen_versions.add(major)
                name = VERSION_NAMES.get(major, "Unknown")
                date_str = post_date.strftime('%Y-%m-%d')
                print(f"{date_str:<12} {version_str:<15} {prod_key:<15} {name:<15}")


def find_latest_version(catalog: dict, major_version: int) -> Optional[Tuple[str, str, str]]:
    """
    Find the latest InstallAssistant for a specific macOS major version.

    Returns (url, version_string, product_key) or None if not found.
    """
    products = find_installassistant_products(catalog)

    print(f"Searching for macOS {major_version} ({VERSION_NAMES.get(major_version, 'Unknown')})...", file=sys.stderr)

    for prod_key, post_date, url, distributions in products:
        dist_url = distributions.get('English', '')
        if not dist_url:
            continue

        version_info = get_version_from_distribution(dist_url)
        if version_info and version_info[0] == major_version:
            major, version_str = version_info
            date_str = post_date.strftime('%Y-%m-%d')
            print(f"Found: {VERSION_NAMES.get(major, 'macOS')} {version_str} (posted {date_str})", file=sys.stderr)
            return (url, version_str, prod_key)

    return None


def download_file(url: str, output_path: Path):
    """Download a file with progress reporting."""
    print(f"Downloading: {url}", file=sys.stderr)
    print(f"Output: {output_path}", file=sys.stderr)

    try:
        with urllib.request.urlopen(url, context=ssl_context) as response:
            total_size = int(response.headers.get('Content-Length', 0))
            block_size = 1024 * 1024  # 1 MB
            downloaded = 0

            output_path.parent.mkdir(parents=True, exist_ok=True)

            with open(output_path, 'wb') as f:
                while True:
                    chunk = response.read(block_size)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)

                    if total_size > 0:
                        percent = (downloaded / total_size) * 100
                        gb_downloaded = downloaded / (1024**3)
                        gb_total = total_size / (1024**3)
                        print(f"\rProgress: {percent:.1f}% ({gb_downloaded:.2f}/{gb_total:.2f} GB)",
                              end='', file=sys.stderr)

            print(f"\nDownload complete: {output_path}", file=sys.stderr)

    except Exception as e:
        print(f"\nError downloading file: {e}", file=sys.stderr)
        if output_path.exists():
            output_path.unlink()
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description='Fetch macOS InstallAssistant.pkg from Apple Software Update Catalog',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --version 14                 # Get latest Sonoma
  %(prog)s --version 13 --output-dir .  # Get Ventura, save in current dir
  %(prog)s --list                       # List available versions
  %(prog)s --version 14 --url-only      # Print URL without downloading
""")

    parser.add_argument('--version', type=int, metavar='VERSION',
                       help='macOS major version to download (11-16)')
    parser.add_argument('--list', action='store_true',
                       help='List available macOS versions')
    parser.add_argument('--url-only', action='store_true',
                       help='Print download URL only, do not download')
    parser.add_argument('--output-dir', type=str, default='.',
                       help='Output directory for downloaded file (default: current directory)')

    args = parser.parse_args()

    # Fetch catalog
    catalog = fetch_catalog()

    # List mode
    if args.list:
        list_available_versions(catalog)
        return

    # Version required for download
    if not args.version:
        parser.error('--version is required (or use --list)')

    if args.version not in VERSION_NAMES:
        print(f"Error: Unsupported macOS version {args.version}", file=sys.stderr)
        print(f"Supported versions: {', '.join(map(str, VERSION_NAMES.keys()))}", file=sys.stderr)
        sys.exit(1)

    # Find latest version
    result = find_latest_version(catalog, args.version)
    if not result:
        print(f"Error: Could not find InstallAssistant for macOS {args.version}", file=sys.stderr)
        sys.exit(1)

    url, version_str, prod_key = result

    # URL-only mode
    if args.url_only:
        print(url)
        return

    # Download
    output_dir = Path(args.output_dir)
    filename = f"InstallAssistant-{VERSION_NAMES[args.version].replace(' ', '')}-{version_str}.pkg"
    output_path = output_dir / filename

    download_file(url, output_path)

    # Output final path for Nix to capture
    print(str(output_path))


if __name__ == '__main__':
    main()
