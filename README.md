# DepthForge 3D

Een zelfstandige, native iPadOS-app voor LiDAR-gestuurde 3D-data-acquisitie. Dit
project wijzigt HouseCapture niet en gebruikt geen netwerkverkeer.

## Wat de app daadwerkelijk doet

- gebruikt een gedeelde `ARSession` voor LiDAR `sceneDepth`, RGB en RoomPlan;
- archiveert geaccepteerde, **onbewerkte** dieptebuffers, confidencebuffers,
  kleurbeelden, cameraposes en intrinsics lokaal;
- fuseert hoge-confidence dieptepunten progressief in een sparse voxelkaart;
- toont een live kwaliteitslaag met meetdichtheid, kijkhoekdiversiteit,
  consistentie en gaten, plus een concrete rescan-instructie;
- maakt checkpoints tijdens het opnemen, hervat een bestaande opname en
  exporteert een portable ZIP met ASCII PLY en RoomPlan-resultaat wanneer
  beschikbaar.

`sceneDepth` is LiDAR-data op de resolutie en nauwkeurigheid die ARKit op het
toestel levert. De app claimt geen sub-millimeternauwkeurigheid: dat is voor de
huidige iPad LiDAR-fysica en ARKit-depthkaart in het algemeen niet
verifieerbaar. Herhaald scannen verhoogt de observatiedichtheid en kan de
ruisrobustheid verbeteren, maar creëert geen niet-gemeten detail.

## Openen en bouwen

Op een Mac met Xcode 16+ en XcodeGen:

```sh
cd DepthForge3D
xcodegen generate
xcodebuild -project DepthForge3D.xcodeproj -scheme DepthForge3D \
  -destination 'generic/platform=iOS' build
```

Voor een echte scan is een iPad met LiDAR nodig (iPadOS 17+). De Simulator kan
de app bouwen maar levert geen ARKit-scenediepte.

## Opnameformaat

Elke opname staat in `Documents/DepthForgeScans/<id>/`:

```text
manifest.json                 opname- en toestelinformatie
frames/index.jsonl            pose, intrinsics, afmetingen en bestandsnamen
frames/000001.depthraw        native ARKit sceneDepth bytes; pixel format and row stride in index
frames/000001.confidence8     UInt8 (0 laag, 1 medium, 2 hoog)
frames/000001.jpg             RGB-camerabeeld
room/room.usdz                RoomPlan-export, indien RoomPlan voltooit
exports/<id>.ply              gefuseerde point cloud
```

Het testscript `tools/benchmark_capture.py` controleert de twee aangeleverde
HouseCapture-ZIPs read-only en vergelijkt hun aanwezige bestanden met het
DepthForge-manifestconcept. Het verandert de brondata niet.
