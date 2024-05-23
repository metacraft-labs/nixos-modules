import subprocess
import os
import time
from prometheus_client import start_http_server, Gauge

PORT = int(os.environ["PORT"])
BASE_PATH = os.environ["BASE_PATH"]
INTERVAL_SEC = int(os.environ["INTERVAL_SEC"])


# Using du rather than os.path.obtainsize since getsize provides the
# apparent directory size and du provides the disk size.
def get_immediate_subdirs_size(BASE_PATH):
    try:
        result = subprocess.run(
            ['du', '--max-depth=1', '--block-size=1', BASE_PATH],
            capture_output=True, text=True, check=True
        )
        lines = result.stdout.strip().split('\n')
        sizes = {}
        for line in lines:
            parts = line.split('\t')
            if len(parts) == 2:
                size, path = parts
                if path != BASE_PATH:
                    sizes[path] = int(size)
        return sizes
    except subprocess.CalledProcessError as e:
        print(f"Error executing du command: {e}")
        return None
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return None


def update_metrics(BASE_PATH, gauge):
    sizes = get_immediate_subdirs_size(BASE_PATH)
    if sizes:
        for path, size in sizes.items():
            gauge.labels(path=path).set(size)
            print(f"`{path}` size is: {size} bytes")
    else:
        print("Could not determine the sizes of the directory contents.")


if __name__ == "__main__":

    dir_size_gauge = Gauge(
        'directory_size_bytes',
        'Size of immediate subdirectories and files in bytes',
        ['path']
    )

    # Start the Prometheus HTTP server on the specified port
    start_http_server(PORT)

    # Continuously update metrics
    while True:
        print("Updating metrics...")
        start_time = time.time()
        update_metrics(BASE_PATH, dir_size_gauge)
        end_time = time.time()
        duration = end_time - start_time
        remaining_time = max(INTERVAL_SEC - duration, 1)
        print(f"Sleeping for {remaining_time:.2f} seconds...")
        time.sleep(remaining_time)
