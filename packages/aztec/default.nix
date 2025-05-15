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
      hash = "sha256-gQcBQN3BE5MHSAztooctb4VQtScx+3CNZlJy/Asya3s=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec";
      hash = "sha256-ztxK3BGL4sn7zpLSvchkI3/rq4kZtShvEdgt7DfgUVw=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-up";
      hash = "sha256-9mJWn+cj8loFkw/RhpV/y1rGapMYYTmiCiDmUJqeqdc=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-nargo";
      hash = "sha256-+Eq1fdEyYihMa5RNQiaMC2319jjCm9Vz4MNIddMRkKY=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-wallet";
      hash = "sha256-Sx/nDFgWi9APZC2uwdRjquq3HSTnT1YdoXBhO3K88dI=";
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
