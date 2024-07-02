{
  lib,
  pkgs,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "pyroscope";
  version = "1.6.1";

  src = fetchFromGitHub {
    owner = "grafana";
    repo = "pyroscope";
    rev = "v${version}";
    hash = "sha256-P2gEL4HhHuAHW0K/ApCwb2RxGVRBuTLMefmGLZOjMSU=";
  };

  vendorHash = "sha256-yMnvN370o7FVDfRE9V7iEPY5ezIchNEzgTItjbhxayo=";
  proxyVendor = true;
  # preConfigure = ''
  #   export GOWORK=off
  # '';

  buildInputs = with pkgs; [gcc pkg-config];
  nativeBuildInputs = buildInputs;

  subPackages = ["cmd/pyroscope" "cmd/profilecli"];

  ldflags = [
    "-X=github.com/grafana/pyroscope/pkg/util/build.Branch=${src.rev}"
    "-X=github.com/grafana/pyroscope/pkg/util/build.Version=${version}"
    "-X=github.com/grafana/pyroscope/pkg/util/build.Revision=${src.rev}"
    "-X=github.com/grafana/pyroscope/pkg/util/build.BuildDate=1970-01-01T00:00:00Z"
  ];

  meta = with lib; {
    description = "Continuous Profiling Platform. Debug performance issues down to a single line of code";
    homepage = "https://github.com/grafana/pyroscope";
    changelog = "https://github.com/grafana/pyroscope/blob/${src.rev}/CHANGELOG.md";
    license = licenses.agpl3Only;
    maintainers = with maintainers; [];
    mainProgram = "pyroscope";
  };
}
