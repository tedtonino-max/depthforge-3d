# DepthForge 3D

Native iPadOS LiDAR-scanner. Bouwen en verpakken gebeurt via de bestaande
GitHub Actions-workflow; de ongesigneerde IPA wordt met iLoader geïnstalleerd.

## Opname

1. Kies Voorwerp of Ruimte.
2. Voorwerp: teken een grondcirkel en stel de hoogte in. Alleen punten binnen
   deze verticale cilinder mogen bijdragen aan het oppervlak en de PLY.
3. Ruimte: start RoomPlan en tik een detailzone aan. Beide modi ondersteunen
   een bevestigde detailring op rechtstreeks gemeten LiDAR-diepte.
4. Loop rustig om het gekozen gebied heen. Mint toont herhaald bevestigde
   oppervlakelementen, verankerd in de wereld. Het camerabeeld blijft zichtbaar.
5. Controleer de scan en scan zo nodig verder. Deel daarna de PLY of bewaar de
   hele scanmap via Bestanden.

## Echte surfel-fusie

`Sources/Core/SurfelFusion.swift` houdt één begrensde kaart met georiënteerde
oppervlakelementen bij. Bestaande elementen worden in nieuwe diepteframes
geprojecteerd en gekoppeld op positie, oppervlaktenormaal en lokaal residu.
Herhaalde frames verbeteren dezelfde positie, kleur en normaal. Geen losse
keyframevlakken, interpolatie over dieptesprongen of opgestapelde meshes.

Alleen hoge confidence wordt geïntegreerd. Er zijn minimaal vier onafhankelijke
frames nodig voor weergave/export. Tegenspraak door zichtbaar vrije ruimte
verwijdert oude geometrie; occlusie doet dat niet. De geometrische consistentie
gebruikt het residu tot het oppervlak, niet de afstand van een bewegende camera.
De PLY bevat bevestigde surfels met normaal, kleur, observatietelling en radius;
het is geen waterdichte, getextureerde driehoeksmesh.

De dekking, meerdere kijkhoeken, residuen en ontbrekende metingen blijven aparte
waarden. De instructie om op te slaan geldt alleen voor het zichtbare gekozen
gebied, niet voor onzichtbare achterkanten. Twee relevante kijkrichtingen moeten
meerdere keren bevestigd zijn. Er is geen abstract kwaliteitspercentage.

## Grenzen en prestaties

- Maximaal 100.000 surfels, 16.000 zichtbare surfels en 24 geselecteerde foto's.
- Eén cameraframe tegelijk in de achtergrondverwerking, inclusief JPEG en schijf.
- Integratielus heeft een 90-ms deadline. Overige stappen hebben harde invoer- en
  elementlimieten; 90 ms is geen garantie voor de totale verwerkingstijd.
- Bij belasting: lagere bemonstering, roterende werkvolgorde, lager opnametempo
  en een zichtbare melding. Bij kritieke warmte wordt de opname gepauzeerd.
- Het live oppervlak wordt aan de huidige diepte getoetst en verborgen zodra
  beweging de laatste zichtbaarheidstest achterhaald maakt.
- Fijnere bemonstering in het object/detailgebied is geen nauwkeurigheidsclaim.
  Onzichtbare of te dunne details worden niet verzonnen.

## Foto's en opnameformaat

Ruwe RGB-beelden blijven gekoppeld aan frames. De fotogalerij gebruikt alleen
beelden met een rustige pose gedurende minimaal 0,8 seconde, bruikbare
belichting, zichtbaar scanonderwerp en een nieuwe kijkhoek. Dit zijn
conservatieve selectiecriteria; er wordt nog geen texture-atlas gemaakt.

```text
manifest.json                 schema depthforge/2, volume, detailzones, fotoselectie
frames/index.jsonl            diepteformaat, row strides, pose, intrinsics, RGB-pad
frames/000001.depthraw        native sceneDepth bytes
frames/000001.confidence8     native confidence
frames/000001.jpg             RGB, ongeroteerd voor dezelfde cameracalibratie
photos/000001-thumb.jpg       georiënteerde thumbnail voor geselecteerd fotomoment
room/room.usdz                RoomPlan indien succesvol
exports/fused-surface.ply     alleen het bevestigde oppervlak
```

## Controleren en bouwen

GitHub Actions draait eerst de tests tegen dezelfde Swift-fusiekern die in de
app wordt gebruikt. Daarna wordt de iPad-app gecompileerd en als één IPA verpakt.
Op een Mac kunnen dezelfde controles handmatig worden uitgevoerd:

```sh
swift test -c release
xcodegen generate
xcodebuild -project DepthForge3D.xcodeproj -scheme DepthForge3D \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Zie `VALIDATION.md` voor de expliciete grenzen van softwaretests en het vereiste
iPad-protocol. LiDAR-kwaliteit en de visuele aansluiting op een echt object
kunnen niet met alleen een groene build worden bewezen.
