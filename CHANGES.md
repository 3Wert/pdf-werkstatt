# Änderungen

## 1.6.1 – 20.10.2026
- Lange Arbeiten (Seite vermessen, Inhalt ändern, Schwärzen, Prüfung) laufen im Hintergrund mit Fortschrittsfenster – die App hängt nicht mehr
- Seiten, deren Text aus Kurven besteht (so schreibt macOS Dateien mit nicht übernehmbaren Schriften), melden klar, was geht und was nicht, statt still nichts zu tun
- Doppelklick auf Text in sehr großen Dateien (> 12 MB) löst keine Gruppen mehr auf (vorher 13 s pro Klick), sondern deckt ab und setzt ein Textfeld – auch für erkannten Text auf Scans

## 1.6 – 20.10.2026
- Passwortgeschützte PDFs: Lesen (RC4, AES-128, AES-256) und Schreiben (AES-256) jetzt im eigenen Leser/Schreiber – beim Sichern bleibt der Originalinhalt erhalten, auch bei Browser-Ausdrucken; PDFKit hatte verschlüsselte Dateien bisher komplett neu gerendert
- Schwärzungen anwenden: Haken „Metadaten entfernen“ (Titel, Autor, Programm, Zeiten, XMP) – standardmäßig an, wird gemerkt
- Schwärzen: Entfernregel und Sicherheitsprüfung beziehen sich auf denselben Kern (Markierung minus 2,5 pt Rand); Zeichen, die überwiegend unter der Markierung liegen, werden auch dann entfernt, wenn sie nur den Rand berühren. Angeschnittene Zeilen führen nicht mehr unnötig zur Bildseite

## 1.5 – 20.10.2026
- Texterkennung (OCR): Werkzeuge › Text erkennen (OCR) … (⌥⌘T) erkennt Text auf gescannten Seiten mit Apple Vision (Deutsch/Englisch, ohne Internet) und legt ihn unsichtbar wortgenau über das Bild – danach durchsuchbar, kopierbar und für „Suchen und schwärzen“ erreichbar; die Darstellung bleibt pixelgleich
- Beim Öffnen eines Scans ohne Textebene wird die Erkennung angeboten
- Schief fotografierte und quer liegende Seiten werden erkannt (vier Drehungen), gedrehte Seiten (/Rotate) ebenfalls
- Schwärzen auf erkannten Seiten entfernt Bildpixel und Textebene zusammen

## 1.4 – 20.10.2026
- Sichern behält den Originalinhalt unveränderter Seiten: Text bleibt durchsuch- und kopierbar, auch bei Browser-Ausdrucken (Chrome/Skia, Type3-Schriften) – PDFKit hatte ihn bisher beim Sichern in Pfade verwandelt. Darstellung pixelgleich, Datei meist kleiner
- Der eigene PDF-Leser versteht jetzt xref-Streams, Objektströme, Hybrid-Dateien sowie ASCII85-/ASCIIHex-Filter
- Schwärzen arbeitet dadurch auf dem Original-Inhalt: Type3-Schriften werden zeichenweise entfernt (Vermessung über Vorschub statt Textmodus), Bilder mit weißer Fläche bleiben deckend, Flächen landen auch bei Skia-Dateien an der richtigen Stelle

## 1.3.1 – 20.10.2026
- Schwärzen: unsichtbarer Text (Texterkennungs-Ebene über Scans) und weißer Text unter der Markierung wird jetzt ebenfalls entfernt – in 1.3 blieb er bei Scans in der Datei
- Schwärzen: neue Prüfung, unabhängig von der Art des Inhalts – das Ergebnis wird ohne die schwarzen Flächen gerendert, unter jeder Markierung darf nichts mehr zu sehen sein; sonst wird die Seite als Bild geschrieben. Fängt z. B. Text, der als Vektorpfade gezeichnet ist (Formulare, Druckvorlagen)
- Zahlen im Seiteninhalt werden genauer geschrieben (6 statt 4 Nachkommastellen) – beim Bearbeiten und Schwärzen verrutscht nichts mehr um Bruchteile eines Punkts

## 1.3 – 19.10.2026
- Echtes Schwärzen: Werkzeuge › Schwärzungen anwenden (⇧⌘R) entfernt den Inhalt unter den Markierungen endgültig – Text zeichenweise (der Rest der Zeile bleibt exakt stehen), Bilder pixelweise, Linien ganz oder beschnitten, Anmerkungen im Bereich; die Datei wird ohne Altstände neu geschrieben
- Schwärzungs-Markierungen zeigen vor dem Anwenden durchscheinend mit rotem Rand, was entfernt wird; nach dem Anwenden steht eine echte schwarze Fläche in der Seite
- Werkzeuge › Suchen und schwärzen … (⌥⌘F): Text, IBAN, E-Mail-Adressen, Telefonnummern oder Datumsangaben im ganzen Dokument markieren
- Prüfung nach dem Anwenden: kein Text mehr auffindbar, Darstellung außerhalb der Schwärzung unverändert; sonst wird die Seite als Bild geschrieben
- Export, Teilen und Sichern fragen, wenn Schwärzungen noch nicht angewendet sind
- „Abdecken“ › „Darunter entfernen“ entfernt jetzt ebenfalls zeichenweise – keine halb abgedeckten Zeilen mehr, die stehen bleiben

## 1.2 – 16.10.2026
- Hilfslinien: Objekte rasten beim Verschieben an Seitenrand, Seitenmitte, Rändern, eigenen Objekten, Text im PDF (Kanten, Grundlinie, Zeilenabstand) sowie Bildern und Linien im PDF ein; ⌘ gedrückt schaltet es aus
- Textfelder rasten mit der Textkante und der Grundlinie ein – zwei Felder exakt übereinander oder bündig unter eine PDF-Zeile
- Auch PDF-Inhalt rastet beim Verschieben ein
- Darstellung › Hilfslinien …: Einrastquellen, Fangbereich, Ränder, Raster, Lineale einstellbar
- Lineale (⌘R) mit Millimetern; eigene Hilfslinien aus dem Lineal ziehen, verschieben, über den Seitenrand ziehen löscht sie; werden je Dokument gemerkt

## 1.1 – 16.10.2026
- Update-Prüfung über GitHub: Hilfe › Nach Updates suchen, automatisch beim Start und alle 4 Stunden
- Seiten aus der Seitenleiste als eigene PDF-Datei auf den Schreibtisch ziehen
- ⌘Z wirkt auch, wenn die Seitenleiste den Fokus hat

## 1.0 – 15.10.2026
- Erste Version
