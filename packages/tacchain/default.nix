{
  lib,
  pkgs,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule rec {
  pname = "tacchain";
  version = "0.0.9";

  src = fetchFromGitHub {
    owner = "TacBuild";
    repo = pname;
    rev = "v${version}";
    hash = "sha256-kU7cMQfbQHzXsBDTFLeR6DWxY1e7l5V2U391tNkdw6w=";
  };

  subPackages = [ "./cmd/tacchaind" ];

  proxyVendor = true;

  vendorHash = "sha256-kXgN2slJG59pWuBKlfotkGzBeIWXESXJHhmwmAK5L/I=";

  tags = "netgo,ledger";

  ldflags = [
    "-X github.com/cosmos/cosmos-sdk/version.Name=tacchain"
    "-X github.com/cosmos/cosmos-sdk/version.AppName=tacchaind"
    "-X github.com/cosmos/cosmos-sdk/version.Version=$(VERSION)"
    "-X github.com/cosmos/cosmos-sdk/version.Commit=$(COMMIT)"
    "-X github.com/cosmos/cosmos-sdk/version.BuildTags=${tags}"
  ];

  buildInputs = with pkgs; [ libusb1 ];

  postInstall = ''
    mkdir -p $out/bin
    for i in contrib/localnet/*.sh; do
      cp $i $out/bin/${pname}-$(basename $i)
    done
  '';

  meta = {
    description = "";
    homepage = "https://github.com/TacBuild/tacchain/tree/main";
    license = lib.licenses.asl20;
    mainProgram = "tacchaind";
  };
}
