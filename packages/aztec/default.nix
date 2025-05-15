{
  stdenv,
  fetchurl,
  lib,
}:
stdenv.mkDerivation {
  name = "aztec";
  srcs = [
    (fetchurl {
      url = "https://install.aztec.network/.aztec-run";
      hash = "sha256-hLLneMb+RE/+btcIz/pK54Diz5N8i4tsKz+1zZatlPQ=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec";
      hash = "sha256-Z3tst1Fn5dQibZzaSnXzPz3DPwY6bkiRSeilM5DZbro=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-up";
      hash = "sha256-9mJWn+cj8loFkw/RhpV/y1rGapMYYTmiCiDmUJqeqdc=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-nargo";
      hash = "sha256-9T9m/Ops1O/uYKNIaBxZ9RC+q7ADQnMjRDU4oTbSORA=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-wallet";
      hash = "sha256-WZvmrVWEnxVRh/zwhaTk6PWSHBD8ElgX8ivODFUUZzU=";
    })
  ];
  sourceRoot = ".";
  unpackCmd = ''
    curTrg=$(basename $(stripHash $curSrc))
    cp $curSrc $curTrg
    chmod +x $curTrg
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp -r * .* $out/bin/
    mv $out/bin/aztec-run $out/bin/.aztec-run
  '';
  meta.mainProgram = "aztec";
}
