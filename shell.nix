{ pkgs ? import <nixpkgs> {} }:

with pkgs;

let
  inherit (lib) optional optionals;

  erlang_wx = erlangR21.override {
    wxSupport = true;
  };

  elixir = (beam.packagesWith erlangR21).elixir.override {
    version = "1.8.2";
      rev = "98485daab0a9f3ac2d7809d38f5e57cd73cb22ac";
      sha256 = "1n77cpcl2b773gmj3m9s24akvj9gph9byqbmj2pvlsmby4aqwckq";
  };
in

mkShell {
  buildInputs = [ elixir git wxmac ]
    ++ optional stdenv.isLinux inotify-tools # For file_system on Linux.
    ++ optionals stdenv.isDarwin (with darwin.apple_sdk.frameworks; [
      # For file_system on macOS.
      CoreFoundation
      CoreServices
    ]);
}
