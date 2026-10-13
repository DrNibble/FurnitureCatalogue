-- Test ciblé : affichage du prix de vente seulement si > craftCost, et tri
-- par défaut MMAvg décroissant (plus haut au plus bas).
-- Hors jeu : harnais Lua 5.1 autonome qui EXTRAIT les blocs exacts des fichiers
-- livrés (Gui.lua, GuiXmlBridge.lua) et les exécute sur des données simulées,
-- pour tester le code réellement modifié (pas des copies).

local passed, failed = 0, 0
local function check(name, cond)
  if cond then
    passed = passed + 1
    print("  OK   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name)
  end
end

local GUI_LUA = "Gui.lua"
local BRIDGE_LUA = "GuiXmlBridge.lua"

-- Extracette de bloc : retourne le texte depuis la ligne qui matche le
-- pattern de début jusqu'au "end" qui ferme la fonction. L'indentation de la
-- ligne de départ est détectée automatiquement ; le "end" de fermeture a la
-- même indentation (précédée du même nombre d'espaces).
local function extractBlock(source, startPattern)
  local lines = {}
  for line in (source .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  local startIdx, startIndent
  for i, line in ipairs(lines) do
    if line:match(startPattern) then
      startIdx = i
      startIndent = line:match("^(%s*)")
      break
    end
  end
  if startIdx == nil then
    return nil, ("bloc introuvable : " .. startPattern)
  end
  -- collecter jusqu'au "end" à la même indentation que la ligne de départ
  local block = {}
  for i = startIdx, #lines do
    table.insert(block, lines[i])
    if lines[i] == (startIndent .. "end") then
      return table.concat(block, "\n")
    end
  end
  return nil, ("bloc non fermé : " .. startPattern)
end

local guiSrc = io.open(GUI_LUA, "r"):read("*a")
local bridgeSrc = io.open(BRIDGE_LUA, "r"):read("*a")

-- ------------------------------------------------------------------ stubs
-- FurC global minimal (Gui.lua définit FurC.SlotTemplate etc. au chargement,
-- on n'extrait que les fonctions ciblées, donc un stub suffit)
FurC = {}

-- api (LibFurnitureCatalogue)
local apiGetItemLink = function(itemId)
  return ("|H1:item:%d:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0|h|h"):format(itemId)
end

-- ---------------------------------------------------------------- extraits
-- 1. getVisibleSaleAverage (bloc ajouté, Gui.lua)
local block1, err1 = extractBlock(guiSrc, "^local function getVisibleSaleAverage")
check("extrait : getVisibleSaleAverage trouvé", block1 ~= nil)
if not block1 then
  print("  ERREUR : " .. tostring(err1))
  os.exit(1)
end

-- 2. formatGoldAmount (déjà présent, non modifié mais nécessaire au test)
local blockFmt, errFmt = extractBlock(guiSrc, "^local function formatGoldAmount")
check("extrait : formatGoldAmount trouvé", blockFmt ~= nil)
if not blockFmt then
  print("  ERREUR : " .. tostring(errFmt))
  os.exit(1)
end

-- 3. bloc du tri (buildSortedIndex est trop long avec tous ses helpers ; on
-- extrait la partie getVisibleSaleAverage + positiveOrNil + getMMAvg qui est
-- ce qui a changé, en évaluant le bloc complet de buildSortedIndex via un
-- environnement minimal et un appel réel sur une DB simulée).
local blockSort, errSort = extractBlock(guiSrc, "^local function buildSortedIndex")
check("extrait : buildSortedIndex trouvé", blockSort ~= nil)
if not blockSort then
  print("  ERREUR : " .. tostring(errSort))
  os.exit(1)
end

-- 4. GuiXmlBridge.lua : blocs sortBy/sortDirection + GuiOnSort + GetSortParams
local bridgeSortBlock, errB1 = extractBlock(bridgeSrc, "^local sortBy")
local bridgeOnSortBlock, errB2 = extractBlock(bridgeSrc, "^function FurC%.GuiOnSort")
local bridgeGetParamsBlock, errB3 = extractBlock(bridgeSrc, "^function FurC%.GetSortParams")
check("extrait : sortBy/sortDirection trouvé", bridgeSortBlock ~= nil)
check("extrait : GuiOnSort trouvé", bridgeOnSortBlock ~= nil)
check("extrait : GetSortParams trouvé", bridgeGetParamsBlock ~= nil)

-- 4b. updateSortButtons (et son helper getButtonTex) : GuiOnSort les
-- appelle ; il faut les extraire aussi pour que le chunk s'exécute.
-- SORT_BUTTON_NAMES est une table multi-lignes fermée par "}", pas "end" :
-- elle est définie inline dans le stub du chunk (mêmes valeurs que le fichier).
local bridgeGetTexBlock, errB5 = extractBlock(bridgeSrc, "^local function getButtonTex")
local bridgeUpdateButtonsBlock, errB6 = extractBlock(bridgeSrc, "^local function updateSortButtons")
check("extrait : getButtonTex trouvé", bridgeGetTexBlock ~= nil)
check("extrait : updateSortButtons trouvé", bridgeUpdateButtonsBlock ~= nil)

-- 5. bloc fillLine (pour le rendu MMAvg) : extrait la sous-partie qui calcule
-- mmAvgText à partir des fonctions locales ; on extrait la fonction fillLine
-- complète et on l'exécute sur un faux curLine/curData.
local blockFill, errFill = extractBlock(guiSrc, "^%s*local function fillLine%(")
check("extrait : fillLine trouvé", blockFill ~= nil)
if not blockFill then
  print("  ERREUR : " .. tostring(errFill))
  os.exit(1)
end

-- fillLine référence des upvalues de Gui.lua non extraites (`sourceFormat`,
-- `getEntry`) : on patche le texte extrait pour les remplacer par des globals
-- du harnais (`sourceFormatGlobal`, `getEntryGlobal`). Les autres références
-- (FurC.*, globals ESO) sont déjà des globals résolus via _G.
local blockFillPatched = blockFill:gsub("sourceFormat%.", "sourceFormatGlobal.")
blockFillPatched = blockFillPatched:gsub("getEntry%(curData%.itemLink%)", "getEntryGlobal(curData.itemLink)")

-- ---------------------------------------------------------------- exécution
-- environnement partagé : les fonctions extraites partagent leurs upvalues
-- via un même chunk ; on concatène tous les blocs dans un seul `load`.

local mmStats = {
  [101] = { avgPrice = 12070, numSales = 15 },
  [102] = { avgPrice = 4000, numSales = 7 },   -- < coût : masqué
  [103] = { avgPrice = 8000, numSales = 2 },   -- == coût : masqué
  [104] = { avgPrice = 20000, numSales = 9 },  -- coût absent : masqué
  [105] = { avgPrice = 30000, numSales = 4 },  -- > coût : visible
}
local mmCraftCost = {
  [101] = 5000,
  [102] = 5000,
  [103] = 8000,
  [104] = nil,
  [105] = 10000,
}

-- le chunk extrait appelle getMasterMerchantStats / getMasterMerchantCraftCostValue
-- qui sont des locales de Gui.lua non extraites ; on les définit comme globaux
-- dans l'environnement du harnais (le bloc extrait les appelle, Lua 5.1
-- résout via _G si non déclarées localement dans le chunk).
-- /!\ les blocs extraits déclarent `local function ...` dans leur propre
-- scope : ils ne se voient pas entre eux si chargés séparément. On les
-- concatène en un seul chunk avec les stubs en tête.
local chunk = table.concat({
  -- stubs communs
  ([[
FurC = FurC or {}
-- GuiOnSort appelle FurC.UpdateGui (défini ailleurs dans Gui.lua) : stub.
FurC.UpdateGui = function() end
local SORT_BUTTON_NAMES = {
  itemName  = "FurCGui_Header_SortBar_Name_Button",
  MMAvg     = "FurCGui_Header_SortBar_MMAvg_Button",
  CraftCost = "FurCGui_Header_SortBar_CraftCost_Button",
}
local function getMasterMerchantStats(link)
  local id = tonumber(link:match("item:(%d+)") or "")
  return mmStatsGlobal[id]
end
local function getMasterMerchantCraftCostValue(link)
  local id = tonumber(link:match("item:(%d+)") or "")
  return mmCraftCostGlobal[id]
end
local function getItemLink(itemId)
  return ("|H1:item:%d:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0|h|h"):format(itemId)
end
]]),
  -- blocs réels extraits de Gui.lua / GuiXmlBridge.lua
  blockFmt,
  block1,
  blockSort,
  blockFillPatched,
  bridgeSortBlock,
  bridgeGetParamsBlock,
  bridgeGetTexBlock,
  bridgeUpdateButtonsBlock,
  bridgeOnSortBlock,
  -- ligne réelle du fichier : expose le setter (hors bloc local, à extraire
  -- séparément)
  "FurC.UpdateSortButtons = updateSortButtons",
  -- retourne les fonctions à tester
  ([[
return {
  getVisibleSaleAverage = getVisibleSaleAverage,
  formatGoldAmount = formatGoldAmount,
  buildSortedIndex = buildSortedIndex,
  fillLine = fillLine,
  FurC = FurC,
  GuiOnSort = FurC.GuiOnSort,
  GetSortParams = FurC.GetSortParams,
  UpdateSortButtons = FurC.UpdateSortButtons,
}
]]),
}, "\n")

-- charger le chunk avec les globaux du harnais (Lua 5.1 : loadstring)
local chunkFn, loadErr
if loadstring then
  chunkFn, loadErr = loadstring(chunk, "extracted")
  -- donner l'environnement du harnais via setfenv
  if chunkFn then
    setfenv(chunkFn, _G)
  end
else
  chunkFn, loadErr = load(chunk, "extracted", "t", _G)
end
check("chunk extrait : charge", chunkFn ~= nil)
if not chunkFn then
  print("  ERREUR load : " .. tostring(loadErr))
  os.exit(1)
end

-- exposer les données MM aux globaux référencés par les stubs du chunk
mmStatsGlobal = mmStats
mmCraftCostGlobal = mmCraftCost

local T = chunkFn()
check("chunk : fonctions exposées", type(T.getVisibleSaleAverage) == "function"
  and type(T.buildSortedIndex) == "function" and type(T.fillLine) == "function")

-- --------------------------------------------------- getVisibleSaleAverage
check("vente > coût : visible", T.getVisibleSaleAverage({ avgPrice = 12070, numSales = 15 }, 5000) == 12070)
check("vente == coût : masqué", T.getVisibleSaleAverage({ avgPrice = 5000 }, 5000) == nil)
check("vente < coût : masqué", T.getVisibleSaleAverage({ avgPrice = 4000 }, 5000) == nil)
check("coût absent : masqué", T.getVisibleSaleAverage({ avgPrice = 12070 }, nil) == nil)
check("coût zéro : masqué", T.getVisibleSaleAverage({ avgPrice = 12070 }, 0) == nil)
check("vente absente : masqué", T.getVisibleSaleAverage(nil, 5000) == nil)
check("vente 0 : masqué", T.getVisibleSaleAverage({ avgPrice = 0 }, 5000) == nil)
check("comparaison valeurs brutes : visible", T.getVisibleSaleAverage({ avgPrice = 5000.4 }, 5000) == 5000.4)
check("comparaison valeurs brutes : masqué", T.getVisibleSaleAverage({ avgPrice = 4999.9 }, 5000) == nil)
check("vente string : masqué", T.getVisibleSaleAverage({ avgPrice = "12070" }, 5000) == nil)

-- ---------------------------------------------------------- buildSortedIndex
local data = {}
for i = 101, 105 do
  data[i] = { itemId = i }
end
-- buildSortedIndex lit FurC.DB (code réel extrait), pas un paramètre.
FurC.DB = data

-- valeurs attendues via getVisibleSaleAverage (fonction réelle extraite)
local expectedVals = {}
for i = 101, 105 do
  local link = ("|H1:item:%d:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0|h|h"):format(i)
  expectedVals[i] = T.getVisibleSaleAverage(mmStats[i], mmCraftCost[i])
end
check("tri : valeurs attendues (101 et 105 visibles)", expectedVals[101] == 12070
  and expectedVals[105] == 30000 and expectedVals[102] == nil
  and expectedVals[103] == nil and expectedVals[104] == nil)

local ids = T.buildSortedIndex("MMAvg", true)
check("tri défaut : 2 entrées visibles", #ids == 5)
check("tri défaut : ordre décroissant", ids[1] == 105 and ids[2] == 101)
check("tri défaut : invisibles à la fin", ids[3] ~= nil and ids[4] ~= nil and ids[5] ~= nil)

local ids2 = T.buildSortedIndex("MMAvg", false)
check("tri inverse : ordre croissant", ids2[1] == 101 and ids2[2] == 105)

-- --------------------------------------------------------------- fillLine
-- un faux curLine/curData pour vérifier le rendu réel (code extrait).
local function newFakeLine()
  local line = {
    hidden = false,
    itemLink = "",
    itemId = 0,
    blueprint = 0,
    nameText = nil, matsText = nil, craftCostText = nil, mmAvgText = nil,
    stationText = nil,
  }
  -- sous-controls (icon, text, station, mats, craftCost, mmAvg) : des tables
  -- avec SetTexture/SetAlpha/SetText stubés. fillLine fait curLine.icon:SetTexture
  -- (GetItemLinkIcon est un global ESO, stubé ci-dessous).
  line.icon = { SetTexture = function(self, v) end, SetAlpha = function(self, v) end }
  line.text = { SetText = function(self, v) line.nameText = v end }
  line.station = { SetText = function(self, v) line.stationText = v end }
  line.mats = { SetText = function(self, v) line.matsText = v end }
  line.craftCost = { SetText = function(self, v) line.craftCostText = v end }
  line.mmAvg = { SetText = function(self, v) line.mmAvgText = v end }
  return line
end
local lineMetatable = {
  __index = function(t, k)
    if k == "SetHidden" then return function(self, h) t.hidden = h end end
    if k == "IsHidden" then return function(self) return t.hidden end end
    if k == "SetTexture" then return function(self, v) end end
    if k == "SetAlpha" then return function(self, v) end end
    if k == "SetVerticalAlignment" then return function(self, v) end end
    if k == "SetHeight" then return function(self, v) end end
    if k == "WasTruncated" then return function(self) return false end end
    if k == "GetFontHeight" then return function(self) return 12 end end
    if k == "GetNamedChild" then
      return function(self, name)
        local sub = { parent = t, name = name }
        setmetatable(sub, {
          __index = function(st, sk)
            if sk == "SetText" then
              return function(ss, v)
                if name == "Name" then t.nameText = v
                elseif name == "Station" then t.stationText = v
                elseif name == "Mats" then t.matsText = v
                elseif name == "CraftCost" then t.craftCostText = v
                elseif name == "MMAvg" then t.mmAvgText = v
                end
              end
            end
            return nil
          end,
        })
        return sub
      end
    end
    return nil
  end,
}

-- stubs des globals que fillLine appelle
fitMats = function(line) end
GetItemLinkIcon = function(itemLink) return "texture.dds" end
GetItemLinkName = function(itemLink) return "name" end
FurC.GetDateFormat = function() return "date" end
FurC.GetSelectedSourceTypes = function() return {} end
FurC.IsFavoriteById = function(itemId) return false end
FurC.showBlueprints = false
FurC.GetEnableShoppingList = function() return false end
sourceFormatGlobal = {
  FormatListText = function(itemId, curData, listOpts, selectedTypes) return "mats" end,
}
getEntryGlobal = function(itemLink) return nil end

local function makeLine()
  local line = newFakeLine()
  setmetatable(line, lineMetatable)
  return line
end

local curDataFor = function(itemId)
  return {
    itemId = itemId,
    itemLink = ("|H1:item:%d:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0|h|h"):format(itemId),
    blueprint = 0,
  }
end

-- dataLines/maxLines : fillLine lit FurCGui_ListHolder.dataLines et .maxLines
FurCGui_ListHolder = {
  dataLines = {},
  maxLines = 60,
}

-- 1. vente > coût : prix + ventes visibles
local line1 = makeLine()
FurCGui_ListHolder.dataLines = { { itemId = 101 }, { itemId = 105 } }
local okFill1 = pcall(T.fillLine, line1, curDataFor(101), 1)
check("fillLine réel : exécution sans erreur (vente > coût)", okFill1)
check("fillLine réel : prix + ventes", line1.mmAvgText == "12 070 (15)")
check("fillLine réel : coût affiché", line1.craftCostText == "5 000")

-- 2. même ligne réutilisée avec vente < coût : cellule vide, pas de résidu
local line2 = makeLine()
local okFill2 = pcall(T.fillLine, line2, curDataFor(102), 1)
check("fillLine réel : exécution sans erreur (vente < coût)", okFill2)
check("fillLine réel : prix masqué, vide", line2.mmAvgText == "")
check("fillLine réel : coût affiché malgré masquage prix", line2.craftCostText == "5 000")

-- 3. vente == coût : masqué
local line3 = makeLine()
local okFill3 = pcall(T.fillLine, line3, curDataFor(103), 1)
check("fillLine réel : vente == coût masqué", okFill3 and line3.mmAvgText == "")

-- 4. coût absent : masqué
local line4 = makeLine()
local okFill4 = pcall(T.fillLine, line4, curDataFor(104), 1)
check("fillLine réel : coût absent masqué", okFill4 and line4.mmAvgText == "")

-- 5. résidu : ligne précédemment remplie puis réutilisée avec prix masqué
local line5 = makeLine()
pcall(T.fillLine, line5, curDataFor(101), 1) -- prix visible
pcall(T.fillLine, line5, curDataFor(102), 1) -- réutilisé avec prix masqué
check("fillLine réel : ligne réutilisée, pas de prix résiduel", line5.mmAvgText == "")

-- 6. station de fabrication : affichée entre parenthèses après le nom
-- FurC.PrintCraftingStation (Chat.lua) retourne " (Station)" ou "" ; on stubbe
-- pour vérifier que fillLine l'appelle bien avec (itemId, curData) et
-- concatène le résultat après le nom.
local stationCalls = {}
FurC.PrintCraftingStation = function(itemId, recipeArray)
  table.insert(stationCalls, { itemId = itemId, hasBlueprint = recipeArray and recipeArray.blueprint ~= nil })
  if itemId == 101 then return " (Bois de charpenterie)" end
  if itemId == 105 then return " (Forge)" end
  return "" -- station inconnue : rien d'ajouté
end

local line6 = makeLine()
local okFill6 = pcall(T.fillLine, line6, curDataFor(101), 1)
check("fillLine réel : exécution sans erreur (station)", okFill6)
check("fillLine réel : PrintCraftingStation appelé", #stationCalls == 1 and stationCalls[1].itemId == 101)
-- le nom reste le lien seul (favori absent) ; la station va dans le Label
-- Station séparé (toujours visible, pas tronquée par l'ellipsis du nom).
check("fillLine réel : nom = lien H0 seul (texte exact)",
  line6.nameText == "|H0:item:101:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0|h|h")
check("fillLine réel : station posée dans le Label Station",
  line6.stationText == " (Bois de charpenterie)")

local line7 = makeLine()
local okFill7 = pcall(T.fillLine, line7, curDataFor(105), 1)
check("fillLine réel : station Forge posée",
  okFill7 and line7.stationText == " (Forge)")

-- station inconnue : Label Station vide, nom = lien seul
local line8 = makeLine()
local okFill8 = pcall(T.fillLine, line8, curDataFor(102), 1)
check("fillLine réel : station inconnue, Label Station vide (texte exact)",
  okFill8 and line8.stationText == ""
    and line8.nameText == "|H0:item:102:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0|h|h")

-- favori : le préfixe "* " reste devant le lien ; station dans son Label
FurC.IsFavoriteById = function(itemId) return itemId == 101 end
local line9 = makeLine()
local okFill9 = pcall(T.fillLine, line9, curDataFor(101), 1)
check("fillLine réel : favori * + lien, station séparée (texte exact)",
  okFill9 and line9.nameText
    == "* |H0:item:101:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0|h|h"
    and line9.stationText == " (Bois de charpenterie)")
FurC.IsFavoriteById = function(itemId) return false end

-- résidu de station : même ligne réutilisée station connue puis station inconnue
local line10 = makeLine()
pcall(T.fillLine, line10, curDataFor(101), 1) -- station connue
pcall(T.fillLine, line10, curDataFor(102), 1) -- réutilisée, station inconnue
check("fillLine réel : ligne réutilisée, pas de station résiduelle",
  line10.nameText ~= nil and line10.nameText:find("Bois", 1, true) == nil)

-- ------------------------------------- PrintCraftingStation réel (exécuté)
-- On extrait la VRAIE FurC.PrintCraftingStation de Chat.lua et on l'exécute
-- avec les dépendances simulées (query.GetCraftingSkillType, GetCraftingSkillName,
-- zo_strformat). Le helper corrigé doit retourner "" pour un type invalide
-- (0 est truthy en Lua) ou un nom vide — pas des parenthèses vides " ()".
local chatSrc = io.open("Chat.lua", "r"):read("*a")
local blockStation, errStation = extractBlock(chatSrc, "^function FurC%.PrintCraftingStation%(")
check("extrait : PrintCraftingStation trouvé", blockStation ~= nil)

if blockStation then
  -- dépendances réelles du helper : query (locale de Chat.lua = FurC.DBQuery),
  -- GetCraftingSkillName (native), sFormat (locale = zo_strformat)
  local stationTests = {
    -- { nom du cas, craftingType retourné, GetCraftingSkillName(type) -> nom, attendu }
    { "type valide (bois)", 5, "Bois de charpenterie", " (Bois de charpenterie)" },
    { "type 0 (invalide, truthy)", 0, "", "" },
    { "type nil", nil, nil, "" },
    { "type valide mais nom vide", 5, "", "" },
    { "type valide mais nom nil", 5, nil, "" },
    { "type négatif", -1, "", "" },
    { "type string (invalide)", "5", nil, "" },
  }
  for _, case in ipairs(stationTests) do
    local caseName, caseType, caseNameReturned, expected = case[1], case[2], case[3], case[4]

    -- stub des dépendances pour ce cas
    FurC.DBQuery = {
      GetCraftingSkillType = function(itemId, recipeArray)
        return caseType
      end,
    }
    GetCraftingSkillName = function(craftingType)
      return caseNameReturned
    end
    zo_strformat = function(fmt, ...)
      -- sFormat(" (<<1>>)", name) : remplacer <<1>> par le premier arg
      return (fmt:gsub("<<1>>", tostring((...))))
    end

    -- charger et exécuter le VRAI helper extrait (le bloc référence `query`
    -- et `sFormat` comme locales de Chat.lua : on patche textuellement)
    local blockStationPatched = blockStation
      :gsub("query%.GetCraftingSkillType", "FurC.DBQuery.GetCraftingSkillType")
      :gsub("sFormat%(", "zo_strformat(")
    local stationFn, stationErr = loadstring(blockStationPatched, "PrintCraftingStation")
    check("PrintCraftingStation extrait : charge (" .. caseName .. ")", stationFn ~= nil)
    if stationFn then
      setfenv(stationFn, _G)
      -- le bloc DÉFINIT FurC.PrintCraftingStation ; on l'exécute ensuite.
      local okDefine, errDefine = pcall(stationFn)
      check("PrintCraftingStation : définition sans erreur (" .. caseName .. ")", okDefine)
      if okDefine then
        local okStation, result = pcall(FurC.PrintCraftingStation, 101, { blueprint = 0 })
        check("PrintCraftingStation réel : exécution (" .. caseName .. ")", okStation)
        check("PrintCraftingStation réel : résultat attendu (" .. caseName .. ")",
          result == expected)
        if result ~= expected then
          print("  attendu " .. string.format("%q", expected)
            .. ", obtenu " .. string.format("%q", tostring(result)))
        end
      else
        print("  ERREUR définition : " .. tostring(errDefine))
      end
    end
  end

  -- vérifier textuellement que le helper a la garde numérique explicite
  check("PrintCraftingStation : garde numérique <= 0 (textuel)",
    blockStation:find("craftingType <= 0", 1, true) ~= nil)
  check("PrintCraftingStation : garde nom vide (textuel)",
    blockStation:find('stationName == ""', 1, true) ~= nil)
end

-- ------------------------------------------------------- tri par défaut réel
-- le bloc GuiXmlBridge.lua extrait définit sortBy/sortDirection LOCALEMENT au
-- chunk ; GetSortParams les expose. On teste via les fonctions exposées.
local sortName, sortDirection = T.GetSortParams()
check("défaut : tri sur MMAvg", sortName == "MMAvg")
check("défaut : direction up", sortDirection == "up")

-- ensureSortedIndex simulé (logique du fichier livré, extraite de la
-- fonction réelle) : sortUp = sortDirection == "up"
local sortUp = (sortDirection == "up")
check("défaut : décroissant (plus haut d'abord, via va > vb)", sortUp == true)

-- GuiOnSort réel (extrait) : premier clic sur MMAvg (déjà actif) inverse
T.GuiOnSort("MMAvg")
local sortName2, sortDirection2 = T.GetSortParams()
check("1er clic MMAvg : direction down (croissant)", sortDirection2 == "down")

T.GuiOnSort("MMAvg")
local _, sortDirection3 = T.GetSortParams()
check("2e clic MMAvg : retour up (décroissant)", sortDirection3 == "up")

-- premier clic sur une autre colonne : sortDirection = "up" (décroissant)
T.GuiOnSort("CraftCost")
local sortName3, _ = T.GetSortParams()
check("clic CraftCost : tri sur CraftCost", sortName3 == "CraftCost")

-- ------------------------------------------------- indicateur initial de tri
-- Remettre le tri sur MMAvg/up (état de la première ouverture) avant de
-- tester InitGui : les clics précédents ont laissé CraftCost actif.
T.GuiOnSort("MMAvg") -- depuis CraftCost : change de colonne, direction "up"
local _, dirBeforeInit = T.GetSortParams()
check("avant InitGui : MMAvg/up restauré", dirBeforeInit == "up")

-- On extrait la VRAIE FurC.InitGui et on l'exécute avec des stubs pour
-- vérifier que FurC.UpdateSortButtons() est bien appelé et pose la texture
-- active sur le bouton MMAvg (list_sortheader_icon_sortup.dds) dès la
-- première ouverture, avant tout clic.
local blockInitGui, errInitGui = extractBlock(guiSrc, "^function FurC%.InitGui%(")
check("extrait : InitGui trouvé", blockInitGui ~= nil)

if blockInitGui then
  -- boutons de tri simulés : SetNormalTexture mémorise la texture posée
  local buttonTextures = {}
  local function makeFakeButton(name)
    local btn = { name = name }
    btn.SetNormalTexture = function(self, tex) buttonTextures[name] = tex end
    _G[name] = btn
    return btn
  end
  makeFakeButton("FurCGui_Header_SortBar_Name_Button")
  makeFakeButton("FurCGui_Header_SortBar_MMAvg_Button")
  makeFakeButton("FurCGui_Header_SortBar_CraftCost_Button")

  -- stubs des autres globals appelés par InitGui
  FurCGui = nil -- le bloc if nil ~= control est alors sauté
  FurC.settings = FurC.settings or { gui = { height = 100, width = 100 } }
  FurC.guiInitialized = false
  createGui = function() end -- locale de Gui.lua : fournie comme global
  FurCGui_ListHolder_Slider = {
    SetMinMax = function(self, min, max) end,
  }
  FurC.UpdateGui = function(...) end
  FurC.GetResetDropdownChoice = function() return nil end
  FurC_Label = {
    GetNamedChild = function(self, name)
      return { SetText = function(ss, v) end }
    end,
  }
  GetString = function(key) return "entries" end
  SI_FURC_LABEL_ENTRIES = "SI_FURC_LABEL_ENTRIES"
  SCENE_MANAGER = {
    RegisterTopLevel = function(self, control, param) end,
  }

  -- exécuter la VRAIE InitGui extraite
  -- Le chunk DÉFINIT FurC.InitGui (il ne l'exécute pas) ; on appelle ensuite
  -- FurC.InitGui() pour exécuter son corps réel, qui doit appeler
  -- FurC.UpdateSortButtons() et poser la texture active sur MMAvg. Aucun
  -- appel direct préalable à UpdateSortButtons : les textures doivent être
  -- vides avant l'appel, sinon le test ne prouve rien.
  check("InitGui : textures vides avant exécution",
    buttonTextures["FurCGui_Header_SortBar_MMAvg_Button"] == nil)

  local initGuiFn, initErr = loadstring(blockInitGui, "InitGui")
  check("InitGui extrait : charge", initGuiFn ~= nil)
  if initGuiFn then
    setfenv(initGuiFn, _G)
    local okDefine, errDefine = pcall(initGuiFn) -- définit FurC.InitGui
    check("InitGui : définition sans erreur", okDefine)
    if not okDefine then print("  ERREUR définition : " .. tostring(errDefine)) end

    -- les textures doivent être encore vides : le corps n'a pas encore tourné
    check("InitGui : textures vides avant appel du corps",
      buttonTextures["FurCGui_Header_SortBar_MMAvg_Button"] == nil)

    -- exécuter le corps réel de FurC.InitGui
    local okInit, errInit = pcall(FurC.InitGui)
    check("InitGui réel : exécution sans erreur", okInit)
    if not okInit then print("  ERREUR InitGui : " .. tostring(errInit)) end
    check("InitGui réel : texture MMAvg active posée (sortup)",
      buttonTextures["FurCGui_Header_SortBar_MMAvg_Button"]
        == "esoui/art/miscellaneous/list_sortheader_icon_sortup.dds")
    check("InitGui réel : texture Name neutre (pas active)",
      buttonTextures["FurCGui_Header_SortBar_Name_Button"]
        == "esoui/art/miscellaneous/list_sortheader_icon_neutral.dds")
    check("InitGui réel : CraftCost neutre (pas actif)",
      buttonTextures["FurCGui_Header_SortBar_CraftCost_Button"]
        == "esoui/art/miscellaneous/list_sortheader_icon_neutral.dds")
  end
end

-- --------------------------- scénario advisor : cache de tri invalidé
-- quand les valeurs MM changent (MM devient disponible, nouvelles ventes).
-- On exécute la VRAIE updateScrollDataLinesData extraite (via ensureSortedIndex
-- et buildDisplayRow aussi extraits) avec getDBRevision stubé (révision fixe)
-- et FurC.MatchFilter stubé (tout accepter). On vérifie que l'ordre est
-- reconstruit avec les nouvelles valeurs MM même sans changement de colonne,
-- de direction ou de révision de DB.

-- boutons/FurCGui_ListHolder déjà stubés ; il faut aussi stuber :
--   - getDBRevision (locale de Gui.lua, extraite via api.GetDBRevision) : on
--     la fournit comme global pour le chunk.
--   - FurC.MatchFilter
--   - FurC_RecipeCount (SetText)
getDBRevisionGlobal = function() return 1 end
FurC.MatchFilter = function(itemId, recipeArray) return true end
FurC_RecipeCount = { SetText = function(self, v) end }

-- extraire ensureSortedIndex, buildDisplayRow, updateScrollDataLinesData
local blockEnsure, errEnsure = extractBlock(guiSrc, "^local function ensureSortedIndex")
local blockBuildRow, errBuildRow = extractBlock(guiSrc, "^local function buildDisplayRow")
local blockUpdateScroll, errUpdateScroll = extractBlock(guiSrc, "^local function updateScrollDataLinesData")
check("extrait : ensureSortedIndex trouvé", blockEnsure ~= nil)
check("extrait : buildDisplayRow trouvé", blockBuildRow ~= nil)
check("extrait : updateScrollDataLinesData trouvé", blockUpdateScroll ~= nil)

if blockEnsure and blockBuildRow and blockUpdateScroll then
  -- patcher getDBRevision → getDBRevisionGlobal (locale de Gui.lua non extraite)
  local blockEnsurePatched = blockEnsure:gsub("getDBRevision%(", "getDBRevisionGlobal(")
  -- patcher buildDisplayRow : ZO_ShallowTableCopy et GetItemLinkName sont des
  -- globals (déjà stubés ZO_ShallowTableCopy ci-dessous) ; on les fournit.
  ZO_ShallowTableCopy = function(t)
    local copy = {}
    for k, v in pairs(t) do copy[k] = v end
    return copy
  end

  -- chunk complet : déclarations partagées + blocs réels + stubs en tête
  local refreshChunk = table.concat({
    ([[
local sortedIndex
local sortedIndexKey
local sortedRevision
local getDBRevisionGlobal = getDBRevisionGlobal
local function getMasterMerchantStats(link)
  local id = tonumber(link:match("item:(%d+)") or "")
  return mmStatsGlobal[id]
end
local function getMasterMerchantCraftCostValue(link)
  local id = tonumber(link:match("item:(%d+)") or "")
  return mmCraftCostGlobal[id]
end
local function getItemLink(itemId)
  return ("|H1:item:%d:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0|h|h"):format(itemId)
end
]]),
    blockFmt,
    block1,
    blockSort,
    blockEnsurePatched,
    blockBuildRow,
    blockUpdateScroll,
    ([[
return {
  updateScrollDataLinesData = updateScrollDataLinesData,
  ensureSortedIndex = ensureSortedIndex,
}
]]),
  }, "\n")

  local refreshFn, refreshErr = loadstring(refreshChunk, "refresh")
  check("chunk rafraîchissement : charge", refreshFn ~= nil)
  if refreshFn then
    setfenv(refreshFn, _G)
    local R = refreshFn()
    check("chunk rafraîchissement : fonctions exposées", type(R.updateScrollDataLinesData) == "function")

    -- reset du tri : MMAvg/up (défaut). Le tri actuel est MMAvg (posé par le
    -- test InitGui ci-dessus), donc un appel direct toggle en "down". On
    -- passe d'abord par CraftCost (change de colonne, direction "up") puis on
    -- revient sur MMAvg (change de colonne, direction "up").
    T.GuiOnSort("CraftCost") -- change de colonne, direction "up"
    T.GuiOnSort("MMAvg") -- change de colonne, direction "up"
    local sbyCheck, sdirCheck = T.GetSortParams()
    check("avant refresh : MMAvg/up restauré", sbyCheck == "MMAvg" and sdirCheck == "up")

    -- premier appel : ordre initial avec les données d'origine
    local ok1 = pcall(R.updateScrollDataLinesData)
    check("updateScrollDataLinesData réel : exécution sans erreur (1)", ok1)
    local dl = FurCGui_ListHolder.dataLines
    check("ordre initial : 105 puis 101 (décroissant)",
      dl[1] and dl[1].itemId == 105 and dl[2] and dl[2].itemId == 101)

    -- changer les valeurs MM (comme si MM avait de nouvelles ventes)
    mmStatsGlobal[101].avgPrice = 50000
    mmStatsGlobal[105].avgPrice = 11000

    -- 2e appel : sans changer colonne/direction/révision DB, l'ordre doit
    -- suivre les nouvelles valeurs (sinon le cache du tri serait resté).
    local ok2 = pcall(R.updateScrollDataLinesData)
    check("updateScrollDataLinesData réel : exécution sans erreur (2)", ok2)
    local dl2 = FurCGui_ListHolder.dataLines
    check("ordre rafraîchi sans changement de tri ni de DB : 101 puis 105",
      dl2[1] and dl2[1].itemId == 101 and dl2[2] and dl2[2].itemId == 105)

    -- restaurer les données pour les tests suivants
    mmStatsGlobal[101].avgPrice = 12070
    mmStatsGlobal[105].avgPrice = 30000
  end
end

-- --------------------------------------------------------------- résumé
print(("\n%d passés, %d échoués"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
