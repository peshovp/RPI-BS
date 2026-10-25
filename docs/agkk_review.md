# АГКК documents review: BGS2005, our transformation chain, reference stations

Review date: 2026-10-25. Read-only review; no code was changed. Everything below is
traceable to a primary document or marked as inference.

## 1. Documents read (primary sources)

| Document | Where | How it was read |
|---|---|---|
| Инструкция № РД-02-20-25 / 20.09.2011 (GNSS) | cadastre.bg `instruction_gnss_dv_2.pdf` | text layer (22 pages) |
| Инструкция № РД-02-20-12 / 03.08.2012 (conversion to BGS2005) | cadastre.bg `instr_bgs2005_08_2012_dv63.pdf` | scanned print, read page images (38 pages) |
| Наредба № 2 / 30.07.2010 (BGS definition) | mrrb.bg `.doc` (RTF) | decoded |
| АГКК "Основни положения за практическо прилагане на БГС2005" (2013) | cadastre.bg `bgs2005-08-10-2013.pdf` | page images; only about the old systems (1970 -> BGS2005), no GNSS content |
| НИГГГ-БАН presentation (проф. Ив. Георгиев) "Нова координатна и височинна системи" | io-bas.bg | text layer |
| EPSG:11185, EPSG:8889 (BGS2005 <-> ETRF2000 / ETRS89) | epsg.io | web |
| BGSTrans package (D:\BGSTransFiles: exe, help, `geoidbul.grd`, `egm96.grd`) | provided by Pesho | help (CHM) read; exe not run |

## 2. What the documents say about the datum

- **Наредба 2/2010, чл.8:** BGS2005 is materialised by the points of the State GPS network and the
  permanent GNSS stations, "определени в ETRS89, Епоха 2005.0". Definitions: epoch 2005.0 = 1 January
  2005, to which the coordinates of the State GPS network points are referred. The Наредба does not
  name an ETRF realisation.
- **РД-02-20-12, чл.2, чл.7:** realised through 7 EUREF points (1996) densified to 25 (2006), the
  EPN station near Sofia, and the State GPS network of 473 points (main + secondary class);
  "определена в епоха 2005.0 г. въз основа на ETRS89".
- **НИГГГ (Georgiev), slide "Резултатите от обработката":** the coordinates in "ETRS89, реализация
  **ETRF2000**, епоха, заедно с техните скорости, са реализация на БГС2005". This is the only
  document that names ETRF2000; it matches the frame used in `bgs2005_transformer.py`.
- **EPSG:11185:** BGS2005 -> ETRF2000 is a zero-parameter operation, **accuracy 0.1 m**, "approximately
  1 cm at the anchor epoch 2005.0 but deteriorates with time".

## 3. Official accuracy of the ETRS89 -> BGS2005 conversion (important)

РД-02-20-12 itself states that converting by formula is rough:

- **чл.39 т.2:** data derived from the Bulref points in ETRF93/epoch 1989.0 and transformed with
  чл.20 are in BGS2005 "с точност до **15 cm**"; better accuracy needs чл.20 ал.4 treatment.
- **чл.40 т.2:** products transformed this way have "средна точност за страната около **10 cm**".
- **чл.36 ал.2 т.1/т.3:** the way to get BGS2005 coordinates properly is to compute from **at least
  three State GPS network points in the survey area or not farther than 50 km**, with a new processing.

Consequence: the horizontal offset of about 12-13 cm that PPP-AR + our chain shows for Topolchane
against the 2025 reference (docs/cors_position.md) is **within the official uncertainty of a
formula-based ETRF2000 -> BGS2005 conversion**. It is therefore not evidence of an error in our
arithmetic. A BGS2005 position at the 5 mm / 10 mm level (РД-02-20-25 чл.7) cannot be obtained by
PPP + transformation alone; it needs a tie to official BGS2005 points (чл.36).

## 4. Check of our chain against the documents

| Item | Result |
|---|---|
| Target frame ETRF2000, epoch 2005.0 | consistent with НИГГГ + Наредба + РД-12 |
| ITRF2020 -> ETRF2000 Helmert (EUREF TN1 Table 4, 14 parameters, PROJ `s` in ppm) | no arithmetic error found; independent check: PPP-AR of SOFI00BGR vs official EPN ETRF2000 differs by E -0.9 / N +1.7 / U +4.2 mm (docs/cors_position.md) |
| Epoch reduction sign and use (`v * (2005.0 - t_obs)`) | correct; SOFI chain vs national BGS2005 coordinates of SOFI: E -3.1 / N -5.7 / U +13.4 mm |
| Velocity | SOFI ETRF2000 velocity as a proxy for all stations; a regional difference of 1-2 mm/yr is 2-4 cm over 21.8 years. This can explain part of the offset, not all. |
| Ellipsoid GRS80 (Наредба Приложение 1) vs WGS84 in pyproj geodetic<->ECEF | difference far below 1 mm; not an error source |
| Ellipsoidal height in the broadcast position | consistent (BGR2005 normal height is display-only) |

Not independently re-derived: the numeric values of EUREF TN1 Table 4 (confirmed only through the
SOFI end-to-end check above).

## 5. Errors / ambiguities found in the АГКК texts (do not apply them literally)

- РД-12 **чл.20 + Приложение 6/7** transform ITRS -> ETRS89 through **epoch 1989.0** (ETRF89/ETRF93
  era), with T-only translations and a plate rotation. It does **not** describe a reduction of a
  new coordinate to epoch 2005.0; that part of our chain is our own interpretation (supported by
  НИГГГ: ETRF2000 coordinates at 2005.0 with velocities).
- **Приложение 7, table 2** ("изменения") is a copy of table 1 and its rotation rates for ITRF2000
  and ITRF2006 are zero; the Eurasian plate rotation rates are missing. The instruction cannot be
  implemented as printed; EUREF TN1 is the correct source.
- Приложение 4 gives ITRF2000 -> older realisations; irrelevant for ITRF2020.
- чл.34 ал.4 / чл.36 ал.2 т.2 refer to ETRF93 epoch 1989.0 for the 15 Bulref points, which the
  instruction itself rates at 15 cm in BGS2005.

Wording corrected in CLAUDE.md: the epoch reduction is not "required by РД-12 Прил.6".
The docstring of `bgs2005_transformer.py` repeats that claim; fix it with the next spec touching
that file.

## 6. Where reference stations / reference coordinates can come from

1. **НИГГГ-БАН, Департамент Геодезия** (national non-commercial permanent GNSS network, maintains the
   State GPS network): "Координатите и скоростите са достъпни/свободни чрез заявка" to
   geodesy@bas.bg or ivan@bas.bg, coordinate accuracy "милиметрова"; part of the stations'
   RINEX data is free on niggg.bas.bg; no real time. The slides are from about 2013, so the station
   list must be confirmed. This is the best source for both **reference coordinates and
   station velocities** (it also closes the Part 10b "station-specific velocity" item).
2. **State GPS network points (473, BGS2005 coordinates, Bulref 15 points also in ETRF93@1989.0):**
   held by АГКК / Геокартфонд (РД-25 чл.23 ал.2: points "определени в БГС 2005, приети от АГКК и
   получени от Геокартфонд"). Requirement for use: at least 3 points, in the area or within 50 km.
3. **АГКК-certified commercial networks** (per НИГГГ slides: NAVITEQ and ГеоНет/Солитех, 30 stations,
   Trimble): the coordinates of their stations are certified in BGS2005 (РД-25 чл.7 ал.1 т.2,
   чл.56 ал.2 т.1 б; list of coordinates is document чл.58 т.4). Whether the user's Trimble network
   (NetR9, station NIK47) is one of them is not established.
4. **EPN SOFI00BGR** (responsible agency BKG): daily RINEX at EPNCB, official ETRF2000 coordinates and
   velocity, national BGS2005 coordinates (BAS/MGS). One station, about 250 km from Topolchane.

Distance limits to respect (РД-25): static relative baseline to a base station **<= 25 km** (чл.12);
tie to State GPS points within **50 km** (РД-12 чл.36). Our 102 km test baseline (Ravda) and the
250 km SOFI baseline are outside the instruction.

## 7. Next steps (proposed, none started)

1. E-mail НИГГГ (geodesy@bas.bg): BGS2005 coordinates **and velocities** of the State GPS network
   points and permanent stations within 50 km of 42.652 N, 26.433 E.
2. Ask АГКК/Геокартфонд for the same, plus whether a published grid or model exists for the
   ETRF2000 -> BGS2005 difference (the BGSTrans grids `geoidbul.grd` is the height surface only).
3. Ask the Trimble network operator for the frame/epoch of NIK47 and whether it is certified.
4. Design a tie-in method: 24 h static from our own RINEX to >= 3 official points within 50 km
   (new code, after the data exists); keep PPP-AR as the independent check.
5. Fix the wording in `bgs2005_transformer.py` docstring (spec for qwen).
