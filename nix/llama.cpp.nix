# The llama.cpp commit Strata builds ggml from (CMakeLists.txt's FetchContent default; third_party/ggml/VERSION.txt
# and setup.py's LLAMA_CPP_COMMIT record the same id). A source-only store path: the pinned tarball is unpacked
# with no build, so -DSTRATA_GGML_DIR in CMake becomes a local add_subdirectory - the sandbox needs no network at
# configure time. It is a regular (not fixed-output) derivation: the input hash is the tarball's, and the output
# is the unpacked source.

{ fetchurl, stdenvNoCC }:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "llama.cpp";
  version = "3cf03257f219afbe7334045ff7c6a06ac68c627d";

  src = fetchurl {
    url = "https://github.com/ggml-org/llama.cpp/archive/${finalAttrs.version}.tar.gz";
    inherit (finalAttrs) hash;
  };
  # the tarball's sha256
  hash = "sha256-wHbXU0r6Dl0OwqDUJbEeeRwW894NcnIhrqBxzvFWooA=";

  # extract into $out directly (the tarball root directory is stripped)
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    mkdir -p $out
    tar -xzf $src -C $out --strip-components=1
  '';

  meta = {
    description = "llama.cpp pinned at Strata's commit: the ggml source the engine is built from";
    license = "mit";
    platforms = [ "x86_64-linux" ];
  };
})
