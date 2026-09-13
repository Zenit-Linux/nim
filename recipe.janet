(def stage (os/getenv "ZPM_PACKAGE_STAGE_DIR"))

(defn fail [msg]
  (eprint "recipe.janet: " msg)
  (os/exit 1))

(defn run [cmd]
  # `os/shell` zwraca kod wyjscia polecenia (jak C-owe system()) --
  # zero == sukces, tak samo jak `set -e` w skrypcie sh.
  (def code (os/shell cmd))
  (unless (zero? code)
    (fail (string "'" cmd "' zakonczone kodem " code))))

(unless stage
  (fail "brak ZPM_PACKAGE_STAGE_DIR w srodowisku -- uruchamiaj przez 'zpk build', nie recipe.janet recznie"))

# Wersja Nim do zbudowania -- nadpisywalna przez NIM_PKG_VERSION (np.
# przy testowaniu nowszej wersji bez edycji recipe). Domyslnie
# najnowsza stabilna galaz 2.2 w chwili pisania tego recipe.
(def nim-version-env (os/getenv "NIM_PKG_VERSION"))
(def nim-version
  (if (and nim-version-env (> (length nim-version-env) 0))
    nim-version-env
    "2.2.12"))

# Jesli zrodla zostaly juz rozpakowane/zbudowane wczesniej w tym samym
# biegu (np. w CI, jako osobny krok), ustaw ZPK_PACKAGING_PREBUILT_NIM_DIR
# na katalog z gotowym `bin/nim` (+ `bin/nimble` itd.), zeby recipe nie
# budowalo po raz drugi -- ten sam mechanizm co ZPK_PACKAGING_PREBUILT_BIN
# we wlasnym recipe zpk.
(def prebuilt (os/getenv "ZPK_PACKAGING_PREBUILT_NIM_DIR"))

(def work-dir (string (os/cwd) "/build-nim-" nim-version))

(def src-dir
  (if (and prebuilt (> (length prebuilt) 0))
    prebuilt
    (do
      (run "command -v curl >/dev/null 2>&1 || { echo \"recipe.janet: brak 'curl' w PATH\" >&2; exit 1; }")
      (run "command -v tar >/dev/null 2>&1 || { echo \"recipe.janet: brak 'tar' w PATH\" >&2; exit 1; }")
      (run (string "command -v " (or (os/getenv "CC") "cc") " >/dev/null 2>&1 || "
                   "echo \"recipe.janet: OSTRZEZENIE -- nie widac kompilatora C w PATH, "
                   "build.sh moze sie nie udac\" >&2"))
      (run (string "rm -rf " work-dir " && mkdir -p " work-dir))
      (run (string "curl -fL --retry 3 -o " work-dir "/nim-" nim-version ".tar.xz "
                   "https://nim-lang.org/download/nim-" nim-version ".tar.xz"))
      (run (string "tar -xf " work-dir "/nim-" nim-version ".tar.xz -C " work-dir))
      (string work-dir "/nim-" nim-version))))

(unless (os/stat src-dir :mode)
  (fail (string "katalog zrodel nie istnieje: " src-dir)))

(unless (and prebuilt (> (length prebuilt) 0))
  # `build.sh` bootstrapuje `bin/nim` z dolaczonych w tarballu
  # `csources` (C) -- respektuje $CC/$CXX, wiec jesli zpk.build ma
  # blok `toolchains{}` dla budowanej architektury, zpk juz ustawilo
  # te zmienne w srodowisku recipe.
  (run (string "cd " src-dir " && sh build.sh"))
  # `koch` to wlasne narzedzie budujace Nim (napisane w Nim) -- kompilujemy
  # je swiezo zbudowanym `bin/nim`, potem nim douczamy sie samego siebie
  # (`koch boot`), na koniec budujemy reszte toolchaina: nimble, nimgrep,
  # nimpretty, nimsuggest, testament.
  (run (string "cd " src-dir " && bin/nim c -d:release --skipUserCfg --skipParentCfg koch"))
  (run (string "cd " src-dir " && ./koch boot -d:release --skipUserCfg --skipParentCfg"))
  (run (string "cd " src-dir " && ./koch tools --skipUserCfg --skipParentCfg")))

(defn have-bin? [name]
  (os/stat (string src-dir "/bin/" name) :mode))

(unless (have-bin? "nim")
  (fail (string "budowanie nie wyprodukowalo " src-dir "/bin/nim")))
(unless (have-bin? "nimble")
  (fail (string "budowanie nie wyprodukowalo " src-dir "/bin/nimble")))

# --- staging ---

# Cala dystrybucja (bin/ + lib/ biblioteki standardowej + config/nim.cfg
# + doc/) ladujemy razem pod jedna, wersjonowana sciezke -- `nim`
# lokalizuje `../lib` i `../config` wzgledem WLASNEGO polozenia, wiec te
# katalogi MUSZA podrozowac razem z binarkami, nie osobno.
(def install-root (string "usr/local/lib/nim-" nim-version))
(def stage-install-dir (string stage "/" install-root))
(def stage-bin-dir (string stage "/usr/local/bin"))

(run (string "mkdir -p " stage-bin-dir))
(run (string "mkdir -p " stage-install-dir))

(each dir ["bin" "lib" "config" "doc"]
  (when (os/stat (string src-dir "/" dir) :mode)
    (run (string "cp -a " src-dir "/" dir " " stage-install-dir "/"))))

(run (string "chmod -R a+rX " stage-install-dir))
(run (string "find " stage-install-dir "/bin -type f -exec chmod +x {} +"))

# Male skrypty-nakladki w usr/local/bin zamiast symlinkow do
# usr/local/lib/nim-<wersja>/bin/<narzedzie> -- .zpk nie gwarantuje
# przenoszenia symlinkow przez kazdy backend instalacyjny zpm, wiec
# bezpieczniej jest uzyc prawdziwego pliku wykonywalnego, ktory po
# prostu `exec`-uje wlasciwa binarke pod absolutna sciezka.
(defn install-wrapper [name]
  (when (have-bin? name)
    (def dest (string stage-bin-dir "/" name))
    (def real-bin (string "/" install-root "/bin/" name))
    (spit dest (string "#!/bin/sh\n"
                        "exec \"" real-bin "\" \"$@\"\n"))
    (run (string "chmod +x " dest))))

(each tool ["nim" "nimble" "nimgrep" "nimpretty" "nimsuggest" "testament"]
  (install-wrapper tool))

(print "recipe.janet: zbudowano i zestagowano Nim " nim-version " -> " install-root)
