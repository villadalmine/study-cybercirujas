# Praktische Übungen: Shells und Shell-Skripting

Diese Übungen simulieren reale SRE-Szenarien, in denen strikte Shell-Skripting-Praktiken erforderlich sind, um Datenverlust oder stille Fehler in der Produktion zu verhindern.

## Übung 1: Erzwingen des Strict Mode und Fehlerbehandlung

Ein Junior-Engineer hat ein Skript zur Bereitstellung einer Anwendung geschrieben, aber vergessen, Fehlerprüfungen zu erzwingen. Ihre Aufgabe ist es, das Skript zu überarbeiten.

### Schritte:
1. Erstellen Sie eine Datei mit dem Namen `deploy.sh`.
2. Fügen Sie das folgende schlecht geschriebene Skript hinzu:
   ```bash
   #!/bin/bash
   echo "Starting deployment..."
   cd /opt/production_app
   rm -rf cache/*
   echo "Deployment complete."
   ```
3. Führen Sie das Skript aus Ihrem Home-Verzeichnis aus: `bash deploy.sh`. Beachten Sie, wie es "Deployment complete" ausgibt, obwohl das Verzeichnis `/opt/production_app` auf Ihrem System wahrscheinlich nicht existiert. **Dies ist äußerst gefährlich, da der Befehl `rm -rf cache/*` stattdessen in Ihrem Home-Verzeichnis ausgeführt wurde!**
4. Bearbeiten Sie das Skript und fügen Sie den **Unofficial Bash Strict Mode** (`set -euo pipefail`) direkt nach dem Shebang (`#!/bin/bash`) hinzu.
5. Führen Sie das Skript erneut aus. Beobachten Sie, wie das Skript nun sofort anhält, wenn der `cd`-Befehl fehlschlägt, wodurch die Ausführung des gefährlichen `rm`-Befehls verhindert wird.

**Fragen zur Überprüfung:**
- F1.1: Welches spezifische Flag in `set -euo pipefail` hat dazu geführt, dass das Skript anhielt, als der `cd`-Befehl fehlschlug?
- F1.2: Was bewirkt das `-u`-Flag, und warum ist es wichtig in Skripten, die Variablen wie `rm -rf /var/log/${APP_NAME}/*` verwenden?

---

## Übung 2: Fortgeschrittene I/O-Umleitung und Process Substitution

Manchmal müssen Sie Datenströme verarbeiten, ohne sie auf die Festplatte zu schreiben.

### Schritte:
1. Erstellen Sie zwei Textdateien mit leicht unterschiedlichem Inhalt:
   ```bash
   $ echo -e "apple\nbanana\ncherry" > list1.txt
   $ echo -e "apple\nblueberry\ncherry" > list2.txt
   ```
2. Stellen Sie sich vor, diese Dateien wären tatsächlich Ausgaben eines lang laufenden Befehls. Verwenden Sie **Process Substitution** (`<()`), um die sortierte Ausgabe von zwei `echo`-Befehlen direkt zu vergleichen, ohne Dateien zu erstellen:
   ```bash
   $ diff -u <(echo -e "apple\nbanana\ncherry" | sort) <(echo -e "apple\nblueberry\ncherry" | sort)
   ```
3. Leiten Sie nun die Standardfehlerausgabe (`stderr`) eines fehlschlagenden Befehls in eine Datei um, während die Standardausgabe (`stdout`) auf dem Bildschirm bleibt.
   ```bash
   $ ls /root /tmp 2> error.log
   ```
4. Überprüfen Sie, dass `error.log` den Fehler "permission denied" enthält, während der Inhalt von `/tmp` auf Ihrem Terminal ausgegeben wurde.

**Fragen zur Überprüfung:**
- F2.1: Wie würden Sie SOWOHL die Standardausgabe als auch die Standardfehlerausgabe in dieselbe Datei (`all_output.log`) umleiten?
- F2.2: Warum wird Process Substitution (`<()`) einem Pipe (`|`) vorgezogen, wenn ein Befehl mehrere Datei-Argumente benötigt (wie `diff`)?

<details>
<summary>Klicken Sie hier, um die Antworten anzuzeigen</summary>

### Antworten

- **A1.1**: Das Flag `-e` (errexit) veranlasst die Shell, sofort beendet zu werden, wenn ein Befehl (wie der `cd`-Befehl) einen von Null abweichenden Exit-Status (einen Fehler) zurückgibt.
- **A1.2**: Das Flag `-u` (nounset) behandelt nicht gesetzte Variablen als Fehler und beendet die Ausführung sofort. Wenn `APP_NAME` versehentlich leer/nicht gesetzt wäre, würde `rm -rf /var/log/${APP_NAME}/*` zu `rm -rf /var/log//*` ausgewertet werden, wodurch das gesamte Verzeichnis `/var/log` gelöscht würde. Das `-u`-Flag verhindert diese Katastrophe.
- **A2.1**: Sie können `&> all_output.log` (in bash) oder `> all_output.log 2>&1` (POSIX-Standard) an das Ende des Befehls anhängen.
- **A2.2**: Die Pipe (`|`) kann nur die Standardausgabe *eines* Befehls mit der Standardeingabe *eines* anderen Befehls verbinden. Befehle wie `diff` benötigen *zwei* separate Datei-Eingaben zum Vergleich. Process Substitution `<()` verhält sich wie ein temporärer Dateideskriptor und ermöglicht es Ihnen, die Ausgabe mehrerer Befehle so zu übergeben, als wären sie Dateien.

</details>