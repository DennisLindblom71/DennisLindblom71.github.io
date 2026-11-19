# Multi Search – iPhone-app

SwiftUI-app som söker på flera marknadsplatser samtidigt och visar varje sajt
i en egen flik inne i appen.

## Funktioner
- Flikar per sajt (Blocket, Tradera, Facebook, Vinted, Sellpy m.fl.) som laddas
  parallellt och ligger kvar när du byter flik
- "Nästa"-knapp och bockar för sajter du har kollat
- Länkar stannar i appen (inga hopp till Blocket-/Facebook-appen)
- Inloggningar (t.ex. Facebook) sparas mellan sökningar
- Historik och sparade sökningar med alla filter
- Spara annonser med ♥ – titel, bild och pris hämtas från sidan och samlas i en lista oavsett sajt
- Påminnelser: om 1 h / 4 h / i morgon, eller varje dag kl 08 eller 18.
  Tryck på notisen så öppnas sökningen direkt.

## Bygga
Projektet genereras med [XcodeGen](https://github.com/yonaskolb/XcodeGen) från `project.yml`:

```bash
cd ios
xcodegen generate
open MultiSearch.xcodeproj
```

## Installera på din iPhone
1. Koppla in iPhonen med kabel och välj den som mål i Xcode.
2. Xcode → MultiSearch-target → **Signing & Capabilities** → välj ditt Apple-ID under *Team*.
3. Tryck ▶ (Run).
4. Första gången: på iPhonen, gå till **Inställningar → Allmänt → VPN och enhetshantering**
   och lita på ditt utvecklarcertifikat. Slå även på **Utvecklarläge** om iPhonen ber om det.

Med ett gratis Apple-ID behöver appen installeras om var 7:e dag.
Med Apple Developer Program (99 USD/år) gäller den i ett år och kan delas via TestFlight.

URL-logiken i `Models.swift` (`Site.url(for:)`) motsvarar `getUrls()` i webbversionen
(`../index.html`) – ändra på båda ställena om en sajt byter sökadress.
