# MOONAI – Medical (not only for) Oncology Open Network For AI

Sumár projektu pre spolupracujúceho rádiológa · 19. 10. 2026, doplnené 20. 10. 2026
Online verzia: https://claude.ai/code/artifact/a84a4f73-52ee-471a-a0bc-c39fe800d3f1
Anglická verzia: [RADIOLOGIST_SUMMARY.md](../RADIOLOGIST_SUMMARY.md)

## Krátky sumár

MOONAI je funkčný prototyp otvorenej platformy, ktorá rádiológovi pomáha ako asistent: segmentuje orgány a lézie, počíta objemy, hľadá podozrivé nálezy a pripravuje návrh štruktúrovaného popisu. Postavený je z overených open-source dielov (MONAI, Orthanc, OHIF, 3D Slicer, TotalSegmentator) a beží celý vnútri nemocnice, takže dáta pacientov nikam neodchádzajú.

**Prečo to robiť.** Komerčné AI asistenty sú drahé a väčšinou pokrývajú jednu oblasť (len mamografiu, len RTG hrudníka, len CT mozgu). MOONAI je jedna platforma pre CT, MR, RTG, mamografiu aj patológiu. Nové funkcie (napríklad segmentáciu ďalšieho orgánu) sa dajú doplniť v dňoch, nie v rokoch.

**Kde sme.** Je to koncept, na ktorom som pracoval približne tri víkendy. Celý reťazec funguje: DICOM, AI model, objemy a návrh popisu. Na testovacom CT sa objem pečene zhoduje s nezávislým nástrojom TotalSegmentator do ~1 %. Výsledky však zatiaľ nie sú klinicky overené.

**Je to legálne?** Ako výskum áno, ako bežný klinický nástroj zatiaľ nie. Softvér, ktorý pomáha pri diagnostike, je podľa EÚ nariadenia MDR zdravotníckou pomôckou, aj keď len dopĺňa lekára a nenahrádza druhé čítanie. Legálne cesty sú tri:

1. Retrospektívna štúdia na anonymizovaných snímkach so súhlasom etickej komisie, bez vplyvu na liečbu pacientov.
2. Klinická štúdia, v ktorej AI beží „v tieni" popri bežnej praxi.
3. Neskôr in-house výnimka MDR pre nástroje vyvinuté a používané v jednej nemocnici, alebo CE certifikácia.

**Navrhovaný ďalší krok.** Malý retrospektívny pilot v jednej oblasti (napríklad volumetria orgánov na CT alebo mamografia): vy označíte vzorku snímok, ja natrénujem a vyhodnotím model a spolu zmeriame, či rádiológovi reálne šetrí čas alebo zachytáva nálezy. Aj ako výskum, nie produkt, to má zmysel. Dlhodobým jadrom projektu je dotrénovanie na dátach nemocnice v oblasti, ktorú komerčné produkty nepokrývajú, napríklad pri nádoroch semenníkov.

## Čo je MOONAI a ako funguje

MOONAI spája prehliadač, úložisko snímok, AI modely a návrh popisu do jedného pracovného postupu. Lekár má vždy posledné slovo.

```
Snímky (PACS: CT, MR, RTG, MMG)
   → Orthanc (DICOM úložisko, anonymizácia pri importe)
   → AI modely MONAI (segmentácia, detekcia; 11 predtrénovaných modelov)
   → Výpočet v kóde (objemy, referenčné rozsahy, príznaky mimo normy)
   → Jazykový model (návrh popisu len z vypočítaných čísel)
   → Rádiológ (prehliadač OHIF / 3D Slicer; kontroluje a podpisuje)
        └─ opravy lekára → Labeling a dotrénovanie → nová verzia modelu → AI modely
```

Snímky idú z PACS cez anonymizáciu do AI modelov. Čísla sa vypočítajú a skontrolujú v kóde, jazykový model z nich len sformuluje návrh textu a rádiológ všetko skontroluje. Jeho opravy sa vracajú ako tréningové dáta, takže modely sa postupne prispôsobujú snímkam a prístrojom konkrétnej nemocnice.

## Aktuálny stav konceptu

Celý reťazec funguje od začiatku do konca na jednom počítači s GPU, alebo pomalšie len na CPU. Klinicky overené zatiaľ nie je nič. Práca zabrala približne tri víkendy.

| Oblasť | Stav | Poznámka |
| --- | --- | --- |
| Infraštruktúra (Orthanc, OHIF, MONAI Label, 3D Slicer) | Funguje | Spúšťa sa jedným skriptom, všetko lokálne |
| Predtrénované modely | 11 modelov nasadených | CT orgány (celé telo, pankreas, VISTA-3D), pľúcne uzly, MR mozog (133 štruktúr, BraTS nádory), MR prostata, hustota prsníka, patológia |
| Volumetria orgánov na CT | Funguje, overené na 1 vyšetrení | Pečeň 1579 cm³ oproti 1595 cm³ z TotalSegmentatora; obličky do 3 % |
| Detekcia pľúcnych uzlov | Technicky funguje | Zatiaľ neoverené na vyšetrení so známym uzlom |
| Návrh popisu cez jazykový model (LLM) | Funguje | Referenčné rozsahy a príznaky sa počítajú v kóde, model ich už nesmie vymýšľať |
| Labeling a dotrénovanie vlastných modelov | Pripravené, nevyskúšané na reálnych dátach | Potrebuje snímky označené lekárom |
| Mamografia | Len klasifikácia hustoty | Detekcia lézií chýba, treba dáta alebo iný model |
| Bezpečnosť, audit, prístupové práva | Chýba | Podmienka pre akékoľvek nasadenie v nemocnici |

Pri ladení sa ukázalo, že najväčšie riziko nie je samotný model, ale to, ako sa výsledky interpretujú. Prvá verzia mala podhodnotené objemy (chybný prevod DICOM). Jazykový model si zase vymýšľal „normálne rozsahy". Obe chyby sú opravené a poučenie je jasné: každé číslo treba overiť proti nezávislému zdroju a lekárovi.

## Má to zmysel?

Áno, ako výskumný projekt s lekárom v slučke. Nie ako rýchla cesta k certifikovanému produktu. Najväčšia hodnota je v tom, že onkoústav získa vlastnú, lacnú a rozšíriteľnú platformu a vlastné označené dáta.

**Prínosy**

- **Volumetria a sledovanie v čase.** Automatické objemy orgánov a lézií ušetria manuálne meranie, napríklad pri hodnotení odpovede na liečbu.
- **Jedna platforma pre viac modalít.** CT, MR, RTG, mamografia aj patológia v jednom prostredí, namiesto viacerých platených licencií.
- **Rýchle labelovanie.** AI navrhne obrys a lekár ho len opraví. Označovanie je tak niekoľkonásobne rýchlejšie než kreslenie od nuly.
- **Vlastné dáta ako aktívum.** Označený súbor snímok z vlastnej populácie a vlastných prístrojov má hodnotu pre výskum, publikácie aj grantové projekty.
- **Dáta zostávajú v nemocnici.** Všetko beží lokálne, žiadny cloud. To výrazne zjednodušuje GDPR.
- **Mamografia.** Výsledky veľkej švédskej štúdie MASAI naznačujú, že AI pri skríningu dokáže znížiť záťaž rádiológov približne o 40 % bez poklesu záchytu (údaj z pamäti, približný). Tam však ide o certifikovaný komerčný systém.

**Limity a riziká**

- **Klinická validácia je hlavná práca.** Model, ktorý funguje na verejných dátach, môže na snímkach z iného prístroja fungovať horšie. Každá úloha potrebuje meranie na vlastných dátach.
- **Automation bias.** Aj „len pomôcka" ovplyvňuje lekára. Falošne negatívny výsledok AI môže znížiť pozornosť.
- **Jazykový model nie je diagnostik.** Smie formulovať len čísla vypočítané kódom. Ak by niečo domýšľal, je to nebezpečné.
- **Kapacita.** Dnes je za projektom jeden človek a niekoľko víkendov. Prevádzka v nemocnici vyžaduje IT podporu, zálohy, aktualizácie a zodpovednú osobu.
- **Právo.** Bez certifikácie alebo výnimky sa výstupy nesmú používať na rozhodovanie o pacientoch (pozri Právny rámec).

## Jadro projektu: trénovanie na dátach nemocnice

Skutočná hodnota MOONAI nevznikne z hotových modelov, ale z ich dotrénovania na snímkach priamo z nemocnice. Najväčší zmysel to má v oblasti, ktorú komerčné produkty nepokrývajú a ktorá je málo preskúmaná, napríklad pri nádoroch semenníkov.

**Čo by to zmenilo na príklade semenníkov**

- **Prázdne miesto na trhu.** Certifikovaný AI produkt ani kvalitný otvorený model pre túto oblasť nepoznám (cielene som to ešte neoveroval). Otvorené modely pre lymfatické uzliny podľa môjho prieskumu chýbajú úplne.
- **Konkrétne úlohy.** Segmentácia a volumetria retroperitoneálnych uzlín na CT a ich sledovanie v čase (odpoveď na chemoterapiu, reziduálne masy). Neskôr prípadne hodnotenie lézií na ultrazvuku.
- **Unikátny dataset.** Označená kohorta z vlastného ústavu je publikovateľná a má hodnotu pre granty.
- **Ľahšia právna cesta.** Keď na trhu nie je ekvivalentný certifikovaný produkt, in-house výnimka MDR sa zdôvodňuje ľahšie.
- **Limit.** Je to zriedkavé ochorenie, takže treba zahrnúť archív za viac rokov.

**Odhad úsilia pre jednu úlohu (napríklad uzliny na CT)**

| Činnosť | Kto | Odhad |
| --- | --- | --- |
| Výber vyšetrení z PACS a anonymizácia | rezident alebo technik, programátor | 2–5 dní |
| Labeling 150–300 vyšetrení s AI predoznačením | 2–3 rádiológovia | 10–20 min na vyšetrenie, spolu približne 25–100 hodín |
| Kontrola testovacej vzorky (približne 50 vyšetrení) | druhý rádiológ | 10–20 hodín |
| Nasadenie v nemocnici, prepojenie s PACS | programátor, IT nemocnice | 1–2 týždne |
| Trénovanie, vyhodnotenie, úpravy | programátor | 1–2 mesiace popri práci |

Reálne to znamená 2–4 hodiny týždenne od 2–3 lekárov počas 2–4 mesiacov. Odhady sú orientačné, spresníme ich po pilotnom označení 10–20 vyšetrení.

**Prevádzka a náklady**

- **Softvér je zadarmo.** Všetky súčasti sú open-source, bez licencií za vyšetrenie. Modely sa dajú kedykoľvek pridať, vymeniť alebo prekonfigurovať. Náklady sú hardvér (jeden GPU server, rádovo jednotky tisíc eur), elektrina a najmä čas ľudí. Niektoré modely majú licenciu len na nekomerčné použitie, čo pre výskum stačí.
- **Výkon.** Na súčasnom hardvéri (jedna GPU RTX PRO 6000 s 96 GB) bežia obrazové modely aj jazykový model naraz na jednej karte. Segmentácia CT trvá rádovo desiatky sekúnd až niekoľko minút. Menšia karta s 32 GB (napríklad RTX 5090) by na spracovanie snímok pravdepodobne stačila tiež, jazykový model by potom bežal na inom počítači. V dávkovom režime cez noc to sú stovky vyšetrení, za týždeň tisíce.
- **Viac používateľov naraz.** Viacerí lekári môžu pracovať súčasne cez webový prehliadač. Úlohy pre GPU sa radia do fronty. Záťažovo to zatiaľ testované nie je.

## Existujúce alternatívy

Alternatívy existujú, ale žiadna nepokryje všetko naraz lacno a pod vlastnou kontrolou. Komerčné produkty sú certifikované, ale platené a väčšinou úzko zamerané. Open-source nástroje sú kvalitné, ale každý rieši len časť úlohy. MOONAI ich spája do jedného pracovného postupu.

| Riešenie | Typ | Zameranie | Vzťah k MOONAI |
| --- | --- | --- | --- |
| Transpara (ScreenPoint), Lunit INSIGHT MMG | Komerčné, CE | Mamografia | Certifikovaná alternatíva pre mamografiu, licencia za vyšetrenie alebo za rok |
| Lunit INSIGHT CXR, Annalise.ai, Gleamer BoneView | Komerčné, CE | RTG hrudníka, fraktúry | Jedna modalita, jedna úloha |
| Aidoc, Siemens AI-Rad Companion | Komerčné, CE | CT nálezy, volumetria | Širšie, ale drahé a viazané na dodávateľa |
| deepc, Blackford, CARPL | Komerčné trhoviská AI | Sprístupnia viac certifikovaných AI naraz | Najbližšia komerčná analógia platformy, platená za každý modul |
| Kaapana (DKFZ Heidelberg) | Open-source platforma | Výskumná AI platforma pre nemocnice | Najbližšia open-source alternatíva, stojí za porovnanie pred ďalším vývojom |
| TotalSegmentator | Open-source | Segmentácia 100+ štruktúr na CT a MR | Už súčasť MOONAI ako referencia |
| nnU-Net, MedSAM | Open-source | Trénovanie vlastných modelov, interaktívna segmentácia | Plánované na trénovanie a rýchly labeling |
| 3D Slicer, MONAI Label, OHIF, Orthanc | Open-source | Prehliadač, anotácia, DICOM úložisko | Stavebné kamene MOONAI |

Názvy a zameranie produktov sú uvedené z pamäti, bez aktuálneho overenia cien a certifikátov.

## Porovnanie: MOONAI, komerčné systémy a ChatGPT / Claude

Každý z troch prístupov je silný v niečom inom. Komerčné systémy majú certifikáciu a validáciu. MOONAI má kontrolu nad dátami, nízku cenu a dá sa rozširovať. Všeobecné chatboty vynikajú v práci s textom, ale na čítanie snímok nie sú stavané.

| Kritérium | MOONAI | Komerčné (Transpara, Aidoc, …) | ChatGPT / Claude so snímkami |
| --- | --- | --- | --- |
| Práca s 3D CT a MR | Plné 3D, Hounsfieldove jednotky, presné mm | Plné 3D | JPG je jeden rez bez HU a 3D kontextu. DICOM otvorí len cez kód, bez overených modelov |
| Presnosť | Segmentácia a volumetria na špičkovej úrovni, detekcia zatiaľ neoverená | Validované na veľkých multicentrických dátach | Pri čítaní snímok často chybujú a vymýšľajú nálezy |
| Certifikácia | Nie, len výskum | CE / MDR | Nie |
| Ochrana dát | Všetko zostáva v nemocnici | On-premise alebo cloud v EÚ so zmluvou | Dáta idú do cloudu mimo nemocnice. DICOM hlavičky obsahujú meno a rodné číslo |
| Cena | Softvér zadarmo, platí sa hardvér a čas | Desaťtisíce eur ročne a viac (napríklad deepc 5–150 tis. GBP ročne za licenciu) | Lacné predplatné s limitmi, API platené za tokeny |
| Šírka a rozšíriteľnosť | Akákoľvek úloha, vlastné modely | Úzke, podľa ponuky dodávateľa | Široké, ale povrchné |
| Text, popisy, literatúra | Lokálny jazykový model, slabší než špičkové | Obmedzené | Najsilnejšie |

**Dostane sa MOONAI s kvalitným jazykovým modelom na úroveň komerčných?** Čiastočne áno, ale nie vďaka jazykovému modelu. Presnosť čítania snímok určujú špecializované obrazové modely. Lepší jazykový model zlepší formuláciu popisu, prácu s nálezmi a agentové úlohy, nie citlivosť detekcie.

- **Segmentácia a volumetria.** Otvorené modely sú na úrovni komerčných. TotalSegmentator je dokonca súčasťou viacerých komerčných produktov schválených v USA.
- **Detekcia (mamografia, RTG hrudníka).** Komerčné systémy sú trénované na veľkých objemoch snímok a validované. Otvorené modely zaostávajú alebo nie sú overené na iných prístrojoch. Napríklad mamografický model Mirai klesol na snímkach iného výrobcu takmer na úroveň náhody.
- **Úzke oblasti (semenníky, uzliny).** Komerčný produkt neexistuje, takže model dotrénovaný na vlastných dátach môže byť najlepší dostupný.
- **Certifikácia.** Tú žiadny jazykový model nenahradí.

**Lokálny agent verzus cloudové služby**

- **Lokálny jazykový model v MOONAI.** Nemá poplatky za tokeny ani limity, môže bežať celú noc nad tisíckami vyšetrení: dávkové spracovanie archívu, porovnanie s predchádzajúcimi vyšetreniami, návrhy popisov. Dáta neopustia nemocnicu. Nevýhodou je, že lokálne modely sú v uvažovaní aj v slovenčine slabšie než špičkové cloudové.
- **Predplatné ChatGPT, Claude alebo Perplexity.** Najvyššia kvalita textu a rešerší, ale s limitmi použitia. Na pacientske dáta sa nehodí.
- **Vlastný agent s plateným API.** Špičková kvalita bez limitov predplatného, ale pri hodinách behu sa náklady rýchlo sčítajú.
- **Odporúčanie: hybrid.** Všetko s pacientskymi dátami beží lokálne (MOONAI a lokálny jazykový model). Úlohy bez pacientskych dát, ako rešerš štúdií alebo odborných odporúčaní, môžu ísť cez cloudové API.

## Právny rámec

To, že AI je „len pomôcka" a nenahrádza druhé čítanie, ju samo osebe nevyníma spod regulácie. Rozhoduje účel použitia: ak výstup softvéru ovplyvňuje diagnostiku konkrétneho pacienta, ide o zdravotnícku pomôcku. Používať MOONAI na výskum je legálne. Na bežnú diagnostiku treba certifikáciu alebo in-house výnimku.

**Tri predpisy, ktoré sa toho týkajú**

- **MDR (nariadenie EÚ 2017/745).** Softvér na podporu diagnostiky je zdravotnícka pomôcka, podľa pravidla 11 spravidla triedy IIa alebo vyššej. Na Slovensku dozor vykonáva ŠÚKL.
- **AI Act (nariadenie EÚ 2024/1689).** AI, ktorá je zdravotníckou pomôckou s posudzovaním notifikovanou osobou, patrí medzi vysokorizikové systémy. Povinnosti pre ňu začnú platiť v auguste 2027 (termín sa môže posunúť). Čistý výskum a vývoj je z AI Actu vyňatý.
- **GDPR a zákon č. 18/2018 Z. z.** Zdravotné údaje sú osobitná kategória. Treba právny základ, anonymizáciu alebo pseudonymizáciu, posúdenie vplyvu (DPIA) a súhlas zodpovednej osoby nemocnice.

**Možné cesty podľa toho, ako sa AI používa**

| Scenár | Vplyv na pacienta | Čo je potrebné | Náročnosť |
| --- | --- | --- | --- |
| Retrospektívny výskum na starších, anonymizovaných snímkach | Žiadny | Etická komisia, dohoda s nemocnicou, anonymizácia, DPIA | Nízka, vhodné na začiatok |
| Labeling a trénovanie modelov na vlastných dátach | Žiadny | To isté ako vyššie | Nízka |
| Prospektívne testovanie „v tieni" (AI beží, ale lekár popisuje ako doteraz) | Žiadny alebo minimálny | Protokol štúdie, etická komisia, pri ovplyvňovaní lekára aj klinická skúška podľa MDR a oznámenie ŠÚKL | Stredná |
| Bežné používanie ako pomôcka pri popise | Áno | In-house výnimka MDR (čl. 5 ods. 5) alebo CE certifikácia | Vysoká |

**In-house výnimka (čl. 5 ods. 5 MDR)** umožňuje nemocnici používať nástroj, ktorý sama vyvinula, bez CE značky. Podmienky sú: nástroj sa neposúva iným subjektom, nemocnica má systém riadenia kvality a dokumentáciu a zdôvodní, prečo jej potreby nepokrýva certifikovaný produkt na trhu. To posledné je pri mamografii ťažšie, lebo certifikované produkty existujú. Pri špecifických onkologických úlohách je to ľahšie.

Toto je orientačný prehľad z pamäti, nie právne stanovisko. Pred začiatkom spolupráce ho treba overiť s právnym oddelením, zodpovednou osobou pre ochranu údajov a etickou komisiou nemocnice.

## Navrhovaný postup spolupráce

Začneme malým retrospektívnym pilotom v jednej oblasti, ktorý nemá žiadny vplyv na pacientov. Každý ďalší krok závisí od nameraných výsledkov predchádzajúceho.

1. **Dohoda a schválenie.** Zmluva o spolupráci alebo výskumný projekt, súhlas etickej komisie, DPIA a zodpovedný lekár na strane nemocnice.
2. **Nasadenie v nemocnici.** MOONAI na samostatnom serveri s GPU v sieti nemocnice, bez prístupu na internet, s anonymizáciou pri importe snímok.
3. **Výber jednej úlohy.** Návrh: volumetria orgánov a lézií na CT (najbližšie k hotovému stavu) alebo detekcia lézií na mamografii (najväčší prínos, ale treba dáta a porovnanie s komerčnými produktmi).
4. **Labeling.** Rádiológ označí alebo opraví AI návrhy na vzorke vyšetrení. Počet určíme podľa úlohy, typicky desiatky až stovky.
5. **Trénovanie a vyhodnotenie.** Dotrénovanie modelu a meranie na oddelenej testovacej vzorke: zhoda s lekárom (Dice, citlivosť, špecificita) a čas ušetrený na jedno vyšetrenie.
6. **Rozhodnutie.** Ak sú výsledky dobré, nasleduje testovanie „v tieni" a prípadne publikácia. Ak nie, úloha sa zmení alebo projekt skončí s nízkymi nákladmi.

Realisticky môže pilot (kroky 2 až 5) trvať niekoľko mesiacov pri práci popri zamestnaní. Najviac času zaberie labeling a schvaľovanie, nie programovanie.

## Otvorené otázky pre rádiológa

- [ ] Ktorá úloha by vám v dennej praxi ušetrila najviac času alebo by najviac pomohla?
- [ ] Kto v nemocnici rozhoduje o výskumnej spolupráci a kto je zodpovedná osoba pre ochranu údajov?
- [ ] Má onkoústav skúsenosť s etickou komisiou pri retrospektívnych štúdiách na snímkach?
- [ ] Dá sa v nemocnici prevádzkovať vlastný server s GPU, alebo treba zariadenie zabezpečiť inak (grant, sponzor)?
- [ ] Koľko času by ste vy alebo kolegovia vedeli venovať labelingu, napríklad hodinu týždenne?
- [ ] Používa už ústav nejaký komerčný AI nástroj alebo o niektorom uvažuje?
