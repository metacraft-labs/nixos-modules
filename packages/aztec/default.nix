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
      hash = "sha256-sM7MgpyDpySicUECwK4TKLvn46qZ7P9GIG++nUMRHyo=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec";
      hash = "sha256-3Ze2sTnEV9Nqso5lLRNUEi214LcoDbFLfGz51bq5T+k=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-up";
      hash = "sha256-Nb6yQt9/k608hEwT6QH2BvjTJ8dinAKbT1gtwP6ClFk=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-nargo";
      hash = "sha256-+Eq1fdEyYihMa5RNQiaMC2319jjCm9Vz4MNIddMRkKY=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-wallet";
      hash = "sha256-JHd5kn1x3UlGVJgk7YPn8pomDFspJKaZFYPT34yQY+s=";
    })
  ];
  sourceRoot = ".";
  unpackCmd = "cp $curSrc $(basename $(stripHash $curSrc))";
  installPhase = ''
    mkdir -p $out/bin
    cp -r * .* $out/bin/
    mv $out/bin/aztec-run $out/bin/.aztec-run
  '';
  meta.mainProgram = "aztec";
}
