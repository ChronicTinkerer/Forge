# release.ps1 -- one-command release helper for the Forge addon family.
#
# Usage (from the Forge folder, in a PowerShell terminal):
#   .\release.ps1 "feat: Forge_AddonManager toolbar overflow fix"
#   .\release.ps1 "fix: ..." -DryRun     # preview, no files touched, no git
#   .\release.ps1 "fix: ..." -NoPush     # bump + commit + tag locally only
#
# What it does:
#   1. Compute a YYMMDDHHMM stamp from the current local clock.
#   2. Rewrite "## Version:" in ALL 594 .toc files (parent + 593 sub-addons).
#      Every addon ships from the same zip, so they get the same stamp.
#   3. git add -A
#   4. git commit -m <message>
#   5. git tag -a <stamp> -m <stamp>     (annotated -- never lightweight)
#   6. git push origin HEAD
#   7. git push origin <stamp>
#   8. Print the GitHub Actions URL.
#
# How the published zip is shaped (see .pkgmeta):
#   The packager moves each Forge/SubAddons/Forge_*/ folder out of Forge/
#   so the zip contains 594 sibling addon folders. Users extract once into
#   AddOns/ and get the parent + all 593 sub-tools as independent installable
#   addons.
#
# If PowerShell blocks the script with an execution policy error:
#     Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Message,

    [switch]$DryRun,

    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'

# ---------- Configuration ------------------------------------------------

$AddonName       = 'Forge'
$RepoOwner       = 'ChronicTinkerer'

# Versioning convention (changed 2026-05-05): sequential integer build
# numbers, +1 per release. Reads the current value from $PrimaryVersionFile
# and writes (N+1) to every TOC in $FilesToBump. If the primary's value is 0
# or missing, the counter starts at 1.
# Rationale: time-stamped versions go non-monotonic when builds happen
# from machines on different timezones (or when a sandbox runs UTC vs
# Eastern). Sequential is always strictly increasing.
# All 10 Forge TOCs share one stamp because they all ship from the same
# zip; users see one coordinated release across the whole family.
$PrimaryVersionFile = 'Forge.toc'

# All 594 toc files get the same stamp on every release. Order is parent
# first, sub-addons alphabetical -- doesn't matter functionally; just for
# readable dry-run output.
$FilesToBump = @(
    @{ Path = 'Forge.toc';                                               Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge (parent) Version' },
    @{ Path = 'SubAddons\Forge_APIRef\Forge_APIRef.toc';                Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef Version' },
    @{ Path = 'SubAddons\Forge_APIRef-AbbreviateConfigAPI\Forge_APIRef-AbbreviateConfigAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-AbbreviateConfigAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-AbbreviatedNumberFormatterAPI\Forge_APIRef-AbbreviatedNumberFormatterAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-AbbreviatedNumberFormatterAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-AccountConstants\Forge_APIRef-AccountConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-AccountConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Action\Forge_APIRef-Action.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Action Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ActionBarShared\Forge_APIRef-ActionBarShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ActionBarShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-AddOnProfilerConstants\Forge_APIRef-AddOnProfilerConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-AddOnProfilerConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-AppearanceSource\Forge_APIRef-AppearanceSource.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-AppearanceSource Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ArrowCalloutConstants\Forge_APIRef-ArrowCalloutConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ArrowCalloutConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-AsyncAssistActionsConstants\Forge_APIRef-AsyncAssistActionsConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-AsyncAssistActionsConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-AuctionHouseConstants\Forge_APIRef-AuctionHouseConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-AuctionHouseConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-AuctionHouseEnums\Forge_APIRef-AuctionHouseEnums.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-AuctionHouseEnums Version' },
    @{ Path = 'SubAddons\Forge_APIRef-AutoCompleteShared\Forge_APIRef-AutoCompleteShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-AutoCompleteShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-AzeriteConstants\Forge_APIRef-AzeriteConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-AzeriteConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-BNetOutage\Forge_APIRef-BNetOutage.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-BNetOutage Version' },
    @{ Path = 'SubAddons\Forge_APIRef-BagConstants\Forge_APIRef-BagConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-BagConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-BagIndexConstants\Forge_APIRef-BagIndexConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-BagIndexConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Base\Forge_APIRef-Base.toc';      Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Base Version' },
    @{ Path = 'SubAddons\Forge_APIRef-BattlePetConstants\Forge_APIRef-BattlePetConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-BattlePetConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-BattlepayConstants\Forge_APIRef-BattlepayConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-BattlepayConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-BountyShared\Forge_APIRef-BountyShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-BountyShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Build\Forge_APIRef-Build.toc';    Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Build Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ButtonState\Forge_APIRef-ButtonState.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ButtonState Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AccessibilityOptions\Forge_APIRef-C_AccessibilityOptions.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AccessibilityOptions Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AccountInfo\Forge_APIRef-C_AccountInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AccountInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AccountStore\Forge_APIRef-C_AccountStore.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AccountStore Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AchievementInfo\Forge_APIRef-C_AchievementInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AchievementInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AchievementTelemetry\Forge_APIRef-C_AchievementTelemetry.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AchievementTelemetry Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ActionBar\Forge_APIRef-C_ActionBar.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ActionBar Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AddOnProfiler\Forge_APIRef-C_AddOnProfiler.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AddOnProfiler Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AddOns\Forge_APIRef-C_AddOns.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AddOns Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AdventureJournal\Forge_APIRef-C_AdventureJournal.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AdventureJournal Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AdventureMap\Forge_APIRef-C_AdventureMap.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AdventureMap Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AlliedRaces\Forge_APIRef-C_AlliedRaces.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AlliedRaces Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AnimaDiversion\Forge_APIRef-C_AnimaDiversion.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AnimaDiversion Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ArdenwealdGardening\Forge_APIRef-C_ArdenwealdGardening.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ArdenwealdGardening Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AreaPoiInfo\Forge_APIRef-C_AreaPoiInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AreaPoiInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ArtifactUI\Forge_APIRef-C_ArtifactUI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ArtifactUI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AssistedCombat\Forge_APIRef-C_AssistedCombat.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AssistedCombat Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AuctionHouse\Forge_APIRef-C_AuctionHouse.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AuctionHouse Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AutoComplete\Forge_APIRef-C_AutoComplete.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AutoComplete Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AzeriteEmpoweredItem\Forge_APIRef-C_AzeriteEmpoweredItem.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AzeriteEmpoweredItem Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AzeriteEssence\Forge_APIRef-C_AzeriteEssence.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AzeriteEssence Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_AzeriteItem\Forge_APIRef-C_AzeriteItem.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_AzeriteItem Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Bank\Forge_APIRef-C_Bank.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Bank Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_BarberShop\Forge_APIRef-C_BarberShop.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_BarberShop Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_BarberShopInternal\Forge_APIRef-C_BarberShopInternal.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_BarberShopInternal Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_BattleNet\Forge_APIRef-C_BattleNet.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_BattleNet Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_BattlePet\Forge_APIRef-C_BattlePet.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_BattlePet Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_BehavioralMessaging\Forge_APIRef-C_BehavioralMessaging.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_BehavioralMessaging Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_BlackMarketInfo\Forge_APIRef-C_BlackMarketInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_BlackMarketInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Browser\Forge_APIRef-C_Browser.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Browser Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CVar\Forge_APIRef-C_CVar.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CVar Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Calendar\Forge_APIRef-C_Calendar.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Calendar Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CampaignInfo\Forge_APIRef-C_CampaignInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CampaignInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CatalogShop\Forge_APIRef-C_CatalogShop.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CatalogShop Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ChallengeMode\Forge_APIRef-C_ChallengeMode.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ChallengeMode Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ChatBubbles\Forge_APIRef-C_ChatBubbles.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ChatBubbles Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ChatInfo\Forge_APIRef-C_ChatInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ChatInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ChromieTime\Forge_APIRef-C_ChromieTime.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ChromieTime Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CinematicList\Forge_APIRef-C_CinematicList.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CinematicList Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ClassColor\Forge_APIRef-C_ClassColor.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ClassColor Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ClassTalents\Forge_APIRef-C_ClassTalents.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ClassTalents Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ClassTrial\Forge_APIRef-C_ClassTrial.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ClassTrial Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ClickBindings\Forge_APIRef-C_ClickBindings.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ClickBindings Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ClientScene\Forge_APIRef-C_ClientScene.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ClientScene Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Club\Forge_APIRef-C_Club.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Club Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ClubFinder\Forge_APIRef-C_ClubFinder.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ClubFinder Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ColorOverrides\Forge_APIRef-C_ColorOverrides.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ColorOverrides Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ColorUtil\Forge_APIRef-C_ColorUtil.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ColorUtil Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CombatAudioAlert\Forge_APIRef-C_CombatAudioAlert.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CombatAudioAlert Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CombatLog\Forge_APIRef-C_CombatLog.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CombatLog Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CombatLogInternal\Forge_APIRef-C_CombatLogInternal.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CombatLogInternal Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CombatLogSecure\Forge_APIRef-C_CombatLogSecure.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CombatLogSecure Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CombatText\Forge_APIRef-C_CombatText.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CombatText Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Commentator\Forge_APIRef-C_Commentator.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Commentator Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CompactUnitFrames\Forge_APIRef-C_CompactUnitFrames.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CompactUnitFrames Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ConfigurationWarnings\Forge_APIRef-C_ConfigurationWarnings.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ConfigurationWarnings Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ConsoleScriptCollection\Forge_APIRef-C_ConsoleScriptCollection.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ConsoleScriptCollection Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Container\Forge_APIRef-C_Container.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Container Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ContentTracking\Forge_APIRef-C_ContentTracking.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ContentTracking Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ContributionCollector\Forge_APIRef-C_ContributionCollector.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ContributionCollector Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CooldownViewer\Forge_APIRef-C_CooldownViewer.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CooldownViewer Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CovenantCallings\Forge_APIRef-C_CovenantCallings.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CovenantCallings Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CovenantPreview\Forge_APIRef-C_CovenantPreview.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CovenantPreview Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CovenantSanctumUI\Forge_APIRef-C_CovenantSanctumUI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CovenantSanctumUI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Covenants\Forge_APIRef-C_Covenants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Covenants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CraftingOrders\Forge_APIRef-C_CraftingOrders.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CraftingOrders Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CreatureInfo\Forge_APIRef-C_CreatureInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CreatureInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CurrencyInfo\Forge_APIRef-C_CurrencyInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CurrencyInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Cursor\Forge_APIRef-C_Cursor.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Cursor Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CursorUtil\Forge_APIRef-C_CursorUtil.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CursorUtil Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_CurveUtil\Forge_APIRef-C_CurveUtil.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_CurveUtil Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_DamageMeter\Forge_APIRef-C_DamageMeter.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_DamageMeter Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_DateAndTime\Forge_APIRef-C_DateAndTime.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_DateAndTime Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_DeathAlert\Forge_APIRef-C_DeathAlert.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_DeathAlert Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_DeathInfo\Forge_APIRef-C_DeathInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_DeathInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_DeathRecap\Forge_APIRef-C_DeathRecap.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_DeathRecap Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_DelvesUI\Forge_APIRef-C_DelvesUI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_DelvesUI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_DuelInfo\Forge_APIRef-C_DuelInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_DuelInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_DurationUtil\Forge_APIRef-C_DurationUtil.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_DurationUtil Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_DyeColor\Forge_APIRef-C_DyeColor.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_DyeColor Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EditMode\Forge_APIRef-C_EditMode.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EditMode Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EncodingUtil\Forge_APIRef-C_EncodingUtil.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EncodingUtil Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EncounterEvents\Forge_APIRef-C_EncounterEvents.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EncounterEvents Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EncounterInfo\Forge_APIRef-C_EncounterInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EncounterInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EncounterJournal\Forge_APIRef-C_EncounterJournal.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EncounterJournal Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EncounterTimeline\Forge_APIRef-C_EncounterTimeline.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EncounterTimeline Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EncounterWarnings\Forge_APIRef-C_EncounterWarnings.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EncounterWarnings Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EndOfMatchUI\Forge_APIRef-C_EndOfMatchUI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EndOfMatchUI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EquipmentSet\Forge_APIRef-C_EquipmentSet.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EquipmentSet Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EventScheduler\Forge_APIRef-C_EventScheduler.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EventScheduler Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EventToastManager\Forge_APIRef-C_EventToastManager.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EventToastManager Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_EventUtils\Forge_APIRef-C_EventUtils.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_EventUtils Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ExpansionTrial\Forge_APIRef-C_ExpansionTrial.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ExpansionTrial Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ExternalEventURL\Forge_APIRef-C_ExternalEventURL.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ExternalEventURL Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_FogOfWar\Forge_APIRef-C_FogOfWar.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_FogOfWar Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_FrameManager\Forge_APIRef-C_FrameManager.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_FrameManager Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_FriendList\Forge_APIRef-C_FriendList.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_FriendList Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_GMTicketInfo\Forge_APIRef-C_GMTicketInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_GMTicketInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_GamePad\Forge_APIRef-C_GamePad.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_GamePad Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_GameRules\Forge_APIRef-C_GameRules.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_GameRules Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Garrison\Forge_APIRef-C_Garrison.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Garrison Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_GenericWidgetDisplay\Forge_APIRef-C_GenericWidgetDisplay.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_GenericWidgetDisplay Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Glue\Forge_APIRef-C_Glue.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Glue Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_GlyphInfo\Forge_APIRef-C_GlyphInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_GlyphInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_GossipInfo\Forge_APIRef-C_GossipInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_GossipInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_GuildBank\Forge_APIRef-C_GuildBank.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_GuildBank Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_GuildInfo\Forge_APIRef-C_GuildInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_GuildInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HeirloomInfo\Forge_APIRef-C_HeirloomInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HeirloomInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HouseEditor\Forge_APIRef-C_HouseEditor.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HouseEditor Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HouseExterior\Forge_APIRef-C_HouseExterior.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HouseExterior Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Housing\Forge_APIRef-C_Housing.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Housing Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HousingBasicMode\Forge_APIRef-C_HousingBasicMode.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HousingBasicMode Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HousingCatalog\Forge_APIRef-C_HousingCatalog.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HousingCatalog Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HousingCleanupMode\Forge_APIRef-C_HousingCleanupMode.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HousingCleanupMode Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HousingCustomizeMode\Forge_APIRef-C_HousingCustomizeMode.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HousingCustomizeMode Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HousingDecor\Forge_APIRef-C_HousingDecor.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HousingDecor Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HousingExpertMode\Forge_APIRef-C_HousingExpertMode.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HousingExpertMode Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HousingInspectMode\Forge_APIRef-C_HousingInspectMode.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HousingInspectMode Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HousingLayout\Forge_APIRef-C_HousingLayout.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HousingLayout Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_HousingNeighborhood\Forge_APIRef-C_HousingNeighborhood.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_HousingNeighborhood Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ImmersiveInteraction\Forge_APIRef-C_ImmersiveInteraction.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ImmersiveInteraction Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_IncomingSummon\Forge_APIRef-C_IncomingSummon.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_IncomingSummon Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_InstanceEncounter\Forge_APIRef-C_InstanceEncounter.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_InstanceEncounter Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_InstanceLeaver\Forge_APIRef-C_InstanceLeaver.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_InstanceLeaver Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_InterfaceFileManifest\Forge_APIRef-C_InterfaceFileManifest.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_InterfaceFileManifest Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_InvasionInfo\Forge_APIRef-C_InvasionInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_InvasionInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_IslandsInfo\Forge_APIRef-C_IslandsInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_IslandsInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_IslandsQueue\Forge_APIRef-C_IslandsQueue.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_IslandsQueue Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Item\Forge_APIRef-C_Item.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Item Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ItemInteraction\Forge_APIRef-C_ItemInteraction.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ItemInteraction Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ItemSocketInfo\Forge_APIRef-C_ItemSocketInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ItemSocketInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ItemText\Forge_APIRef-C_ItemText.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ItemText Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ItemUpgrade\Forge_APIRef-C_ItemUpgrade.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ItemUpgrade Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_KeyBindings\Forge_APIRef-C_KeyBindings.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_KeyBindings Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LFGInfo\Forge_APIRef-C_LFGInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LFGInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LFGList\Forge_APIRef-C_LFGList.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LFGList Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LegendaryCrafting\Forge_APIRef-C_LegendaryCrafting.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LegendaryCrafting Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LevelLink\Forge_APIRef-C_LevelLink.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LevelLink Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LevelSquish\Forge_APIRef-C_LevelSquish.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LevelSquish Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LimitedInput\Forge_APIRef-C_LimitedInput.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LimitedInput Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LiveEvent\Forge_APIRef-C_LiveEvent.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LiveEvent Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LoadingScreen\Forge_APIRef-C_LoadingScreen.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LoadingScreen Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LobbyMatchmakerInfo\Forge_APIRef-C_LobbyMatchmakerInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LobbyMatchmakerInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Log\Forge_APIRef-C_Log.toc';    Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Log Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Loot\Forge_APIRef-C_Loot.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Loot Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LootHistory\Forge_APIRef-C_LootHistory.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LootHistory Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LootJournal\Forge_APIRef-C_LootJournal.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LootJournal Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LoreText\Forge_APIRef-C_LoreText.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LoreText Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_LossOfControl\Forge_APIRef-C_LossOfControl.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_LossOfControl Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_MacOptions\Forge_APIRef-C_MacOptions.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_MacOptions Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Macro\Forge_APIRef-C_Macro.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Macro Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Mail\Forge_APIRef-C_Mail.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Mail Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_MajorFactions\Forge_APIRef-C_MajorFactions.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_MajorFactions Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Map\Forge_APIRef-C_Map.toc';    Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Map Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_MapExplorationInfo\Forge_APIRef-C_MapExplorationInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_MapExplorationInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_MerchantFrame\Forge_APIRef-C_MerchantFrame.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_MerchantFrame Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Minimap\Forge_APIRef-C_Minimap.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Minimap Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ModelInfo\Forge_APIRef-C_ModelInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ModelInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ModifiedInstance\Forge_APIRef-C_ModifiedInstance.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ModifiedInstance Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_MountJournal\Forge_APIRef-C_MountJournal.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_MountJournal Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_MythicPlus\Forge_APIRef-C_MythicPlus.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_MythicPlus Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_NamePlate\Forge_APIRef-C_NamePlate.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_NamePlate Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_NamePlateManager\Forge_APIRef-C_NamePlateManager.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_NamePlateManager Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Navigation\Forge_APIRef-C_Navigation.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Navigation Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_NeighborhoodInitiative\Forge_APIRef-C_NeighborhoodInitiative.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_NeighborhoodInitiative Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_NewItems\Forge_APIRef-C_NewItems.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_NewItems Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PaperDollInfo\Forge_APIRef-C_PaperDollInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PaperDollInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PartyInfo\Forge_APIRef-C_PartyInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PartyInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PartyPose\Forge_APIRef-C_PartyPose.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PartyPose Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PerksActivities\Forge_APIRef-C_PerksActivities.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PerksActivities Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PerksProgram\Forge_APIRef-C_PerksProgram.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PerksProgram Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PetBattles\Forge_APIRef-C_PetBattles.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PetBattles Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PetInfo\Forge_APIRef-C_PetInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PetInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PetJournal\Forge_APIRef-C_PetJournal.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PetJournal Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PhotoSharing\Forge_APIRef-C_PhotoSharing.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PhotoSharing Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Ping\Forge_APIRef-C_Ping.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Ping Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PingSecure\Forge_APIRef-C_PingSecure.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PingSecure Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Platform\Forge_APIRef-C_Platform.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Platform Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PlayerChoice\Forge_APIRef-C_PlayerChoice.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PlayerChoice Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PlayerInfo\Forge_APIRef-C_PlayerInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PlayerInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PlayerInteractionManager\Forge_APIRef-C_PlayerInteractionManager.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PlayerInteractionManager Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PlayerMentorship\Forge_APIRef-C_PlayerMentorship.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PlayerMentorship Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Pony\Forge_APIRef-C_Pony.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Pony Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ProfSpecs\Forge_APIRef-C_ProfSpecs.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ProfSpecs Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_PvP\Forge_APIRef-C_PvP.toc';    Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_PvP Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_QuestHub\Forge_APIRef-C_QuestHub.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_QuestHub Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_QuestInfoSystem\Forge_APIRef-C_QuestInfoSystem.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_QuestInfoSystem Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_QuestItemUse\Forge_APIRef-C_QuestItemUse.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_QuestItemUse Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_QuestLine\Forge_APIRef-C_QuestLine.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_QuestLine Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_QuestLog\Forge_APIRef-C_QuestLog.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_QuestLog Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_QuestOffer\Forge_APIRef-C_QuestOffer.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_QuestOffer Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_QuestSession\Forge_APIRef-C_QuestSession.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_QuestSession Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_RaidLocks\Forge_APIRef-C_RaidLocks.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_RaidLocks Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_RecentAllies\Forge_APIRef-C_RecentAllies.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_RecentAllies Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_RecruitAFriend\Forge_APIRef-C_RecruitAFriend.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_RecruitAFriend Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_RemixArtifactUI\Forge_APIRef-C_RemixArtifactUI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_RemixArtifactUI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ReportSystem\Forge_APIRef-C_ReportSystem.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ReportSystem Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Reputation\Forge_APIRef-C_Reputation.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Reputation Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ResearchInfo\Forge_APIRef-C_ResearchInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ResearchInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_RestrictedActions\Forge_APIRef-C_RestrictedActions.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_RestrictedActions Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ScenarioInfo\Forge_APIRef-C_ScenarioInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ScenarioInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ScrappingMachineUI\Forge_APIRef-C_ScrappingMachineUI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ScrappingMachineUI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ScriptWarnings\Forge_APIRef-C_ScriptWarnings.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ScriptWarnings Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ScriptedAnimations\Forge_APIRef-C_ScriptedAnimations.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ScriptedAnimations Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SeasonInfo\Forge_APIRef-C_SeasonInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SeasonInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Secrets\Forge_APIRef-C_Secrets.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Secrets Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SecureTransfer\Forge_APIRef-C_SecureTransfer.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SecureTransfer Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SettingsUtil\Forge_APIRef-C_SettingsUtil.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SettingsUtil Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SkillInfo\Forge_APIRef-C_SkillInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SkillInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SocialQueue\Forge_APIRef-C_SocialQueue.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SocialQueue Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SocialRestrictions\Forge_APIRef-C_SocialRestrictions.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SocialRestrictions Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Soulbinds\Forge_APIRef-C_Soulbinds.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Soulbinds Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Sound\Forge_APIRef-C_Sound.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Sound Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SpecializationInfo\Forge_APIRef-C_SpecializationInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SpecializationInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Spell\Forge_APIRef-C_Spell.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Spell Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SpellActivationOverlay\Forge_APIRef-C_SpellActivationOverlay.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SpellActivationOverlay Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SpellBook\Forge_APIRef-C_SpellBook.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SpellBook Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SpellDiminish\Forge_APIRef-C_SpellDiminish.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SpellDiminish Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SplashScreen\Forge_APIRef-C_SplashScreen.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SplashScreen Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_StableInfo\Forge_APIRef-C_StableInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_StableInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_StorePublic\Forge_APIRef-C_StorePublic.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_StorePublic Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_StringUtil\Forge_APIRef-C_StringUtil.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_StringUtil Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SummonInfo\Forge_APIRef-C_SummonInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SummonInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SuperTrack\Forge_APIRef-C_SuperTrack.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SuperTrack Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_System\Forge_APIRef-C_System.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_System Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_SystemVisibilityManager\Forge_APIRef-C_SystemVisibilityManager.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_SystemVisibilityManager Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TTSSettings\Forge_APIRef-C_TTSSettings.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TTSSettings Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TableUtil\Forge_APIRef-C_TableUtil.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TableUtil Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TalkingHead\Forge_APIRef-C_TalkingHead.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TalkingHead Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TaskQuest\Forge_APIRef-C_TaskQuest.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TaskQuest Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TaxiMap\Forge_APIRef-C_TaxiMap.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TaxiMap Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Texture\Forge_APIRef-C_Texture.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Texture Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Timer\Forge_APIRef-C_Timer.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Timer Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TimerunningUI\Forge_APIRef-C_TimerunningUI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TimerunningUI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TooltipComparison\Forge_APIRef-C_TooltipComparison.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TooltipComparison Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TooltipInfo\Forge_APIRef-C_TooltipInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TooltipInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ToyBoxInfo\Forge_APIRef-C_ToyBoxInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ToyBoxInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TradeInfo\Forge_APIRef-C_TradeInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TradeInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TradeSkillUI\Forge_APIRef-C_TradeSkillUI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TradeSkillUI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Trainer\Forge_APIRef-C_Trainer.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Trainer Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TraitConfig\Forge_APIRef-C_TraitConfig.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TraitConfig Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Traits\Forge_APIRef-C_Traits.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Traits Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Transmog\Forge_APIRef-C_Transmog.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Transmog Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TransmogCollection\Forge_APIRef-C_TransmogCollection.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TransmogCollection Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TransmogOutfitInfo\Forge_APIRef-C_TransmogOutfitInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TransmogOutfitInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_TransmogSets\Forge_APIRef-C_TransmogSets.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_TransmogSets Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Tutorial\Forge_APIRef-C_Tutorial.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Tutorial Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_UI\Forge_APIRef-C_UI.toc';      Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_UI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_UIActionHandler\Forge_APIRef-C_UIActionHandler.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_UIActionHandler Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_UIColor\Forge_APIRef-C_UIColor.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_UIColor Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_UIWidgetManager\Forge_APIRef-C_UIWidgetManager.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_UIWidgetManager Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_UnitAuras\Forge_APIRef-C_UnitAuras.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_UnitAuras Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_UserFeedback\Forge_APIRef-C_UserFeedback.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_UserFeedback Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_Vehicle\Forge_APIRef-C_Vehicle.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_Vehicle Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_VideoOptions\Forge_APIRef-C_VideoOptions.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_VideoOptions Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_VignetteInfo\Forge_APIRef-C_VignetteInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_VignetteInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_VoiceChat\Forge_APIRef-C_VoiceChat.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_VoiceChat Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_WarbandScene\Forge_APIRef-C_WarbandScene.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_WarbandScene Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_WeeklyRewards\Forge_APIRef-C_WeeklyRewards.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_WeeklyRewards Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_WorldLootObject\Forge_APIRef-C_WorldLootObject.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_WorldLootObject Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_WorldSafeLocsUIInternal\Forge_APIRef-C_WorldSafeLocsUIInternal.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_WorldSafeLocsUIInternal Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_WorldStateInfo\Forge_APIRef-C_WorldStateInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_WorldStateInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_WowEntitlementInfo\Forge_APIRef-C_WowEntitlementInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_WowEntitlementInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_WowSurvey\Forge_APIRef-C_WowSurvey.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_WowSurvey Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_WowTokenUI\Forge_APIRef-C_WowTokenUI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_WowTokenUI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_XMLUtil\Forge_APIRef-C_XMLUtil.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_XMLUtil Version' },
    @{ Path = 'SubAddons\Forge_APIRef-C_ZoneAbility\Forge_APIRef-C_ZoneAbility.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-C_ZoneAbility Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CalendarConstants\Forge_APIRef-CalendarConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CalendarConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Camera\Forge_APIRef-Camera.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Camera Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CameraConstants\Forge_APIRef-CameraConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CameraConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CatalogShopConstants\Forge_APIRef-CatalogShopConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CatalogShopConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CharacterCreationConstants\Forge_APIRef-CharacterCreationConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CharacterCreationConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CharacterSelectionConstants\Forge_APIRef-CharacterSelectionConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CharacterSelectionConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CharacterServicesConstants\Forge_APIRef-CharacterServicesConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CharacterServicesConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ChatConstants\Forge_APIRef-ChatConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ChatConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ChatShared\Forge_APIRef-ChatShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ChatShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Cinematic\Forge_APIRef-Cinematic.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Cinematic Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CinematicConstants\Forge_APIRef-CinematicConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CinematicConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ClickBindingsConstants\Forge_APIRef-ClickBindingsConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ClickBindingsConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Client\Forge_APIRef-Client.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Client Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ClientSettings\Forge_APIRef-ClientSettings.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ClientSettings Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ClubShared\Forge_APIRef-ClubShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ClubShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Color\Forge_APIRef-Color.toc';    Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Color Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ColorOverrideConstants\Forge_APIRef-ColorOverrideConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ColorOverrideConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CombatAudioAlertConstants\Forge_APIRef-CombatAudioAlertConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CombatAudioAlertConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CombatAudioAlertShared\Forge_APIRef-CombatAudioAlertShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CombatAudioAlertShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CombatLogConstants\Forge_APIRef-CombatLogConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CombatLogConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CombatLogShared\Forge_APIRef-CombatLogShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CombatLogShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CombatTextShared\Forge_APIRef-CombatTextShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CombatTextShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CommentatorShared\Forge_APIRef-CommentatorShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CommentatorShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ConfigurationWarningConstants\Forge_APIRef-ConfigurationWarningConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ConfigurationWarningConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ConnectionScript\Forge_APIRef-ConnectionScript.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ConnectionScript Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Console\Forge_APIRef-Console.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Console Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ContentTrackingTypes\Forge_APIRef-ContentTrackingTypes.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ContentTrackingTypes Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CooldownFrameConstants\Forge_APIRef-CooldownFrameConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CooldownFrameConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CooldownViewerConstants\Forge_APIRef-CooldownViewerConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CooldownViewerConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CovenantCallingsConstants\Forge_APIRef-CovenantCallingsConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CovenantCallingsConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CovenantSanctumConstants\Forge_APIRef-CovenantSanctumConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CovenantSanctumConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CovenantsConstants\Forge_APIRef-CovenantsConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CovenantsConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CraftingOrderUIConstants\Forge_APIRef-CraftingOrderUIConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CraftingOrderUIConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CraftingOrderUIShared\Forge_APIRef-CraftingOrderUIShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CraftingOrderUIShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CurrencyConstants_Mainline\Forge_APIRef-CurrencyConstants_Mainline.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CurrencyConstants_Mainline Version' },
    @{ Path = 'SubAddons\Forge_APIRef-CursorConst\Forge_APIRef-CursorConst.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-CursorConst Version' },
    @{ Path = 'SubAddons\Forge_APIRef-DamageConstants\Forge_APIRef-DamageConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-DamageConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-DamageMeterConstants\Forge_APIRef-DamageMeterConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-DamageMeterConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-DebugToggle\Forge_APIRef-DebugToggle.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-DebugToggle Version' },
    @{ Path = 'SubAddons\Forge_APIRef-DelvesConstants\Forge_APIRef-DelvesConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-DelvesConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-DungeonEncounterConstants\Forge_APIRef-DungeonEncounterConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-DungeonEncounterConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-DyeColorInfoShared\Forge_APIRef-DyeColorInfoShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-DyeColorInfoShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-EditModeManagerConstants\Forge_APIRef-EditModeManagerConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-EditModeManagerConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-EditModeManagerConstants_Mainline\Forge_APIRef-EditModeManagerConstants_Mainline.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-EditModeManagerConstants_Mainline Version' },
    @{ Path = 'SubAddons\Forge_APIRef-EncodingUtilConstants\Forge_APIRef-EncodingUtilConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-EncodingUtilConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-EncounterEventsShared\Forge_APIRef-EncounterEventsShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-EncounterEventsShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-EncounterJournalConstants\Forge_APIRef-EncounterJournalConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-EncounterJournalConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-EncounterTimelineConstants\Forge_APIRef-EncounterTimelineConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-EncounterTimelineConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-EventSchedulerConstants\Forge_APIRef-EventSchedulerConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-EventSchedulerConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Expansion\Forge_APIRef-Expansion.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Expansion Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ExpansionConstants\Forge_APIRef-ExpansionConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ExpansionConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ExpansionInfo\Forge_APIRef-ExpansionInfo.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ExpansionInfo Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ExpansionLevelConstants\Forge_APIRef-ExpansionLevelConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ExpansionLevelConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Font\Forge_APIRef-Font.toc';      Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Font Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPIArchaeologyDigSiteFrame\Forge_APIRef-FrameAPIArchaeologyDigSiteFrame.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPIArchaeologyDigSiteFrame Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPIBlob\Forge_APIRef-FrameAPIBlob.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPIBlob Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPICharacterModelBase\Forge_APIRef-FrameAPICharacterModelBase.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPICharacterModelBase Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPICinematicModel\Forge_APIRef-FrameAPICinematicModel.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPICinematicModel Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPICooldown\Forge_APIRef-FrameAPICooldown.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPICooldown Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPIDressUpModel\Forge_APIRef-FrameAPIDressUpModel.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPIDressUpModel Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPIFogOfWarFrame\Forge_APIRef-FrameAPIFogOfWarFrame.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPIFogOfWarFrame Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPIModelSceneFrame\Forge_APIRef-FrameAPIModelSceneFrame.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPIModelSceneFrame Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPIModelSceneFrameActor\Forge_APIRef-FrameAPIModelSceneFrameActor.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPIModelSceneFrameActor Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPIModelSceneFrameActorBase\Forge_APIRef-FrameAPIModelSceneFrameActorBase.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPIModelSceneFrameActorBase Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPIModelSceneFrameShared\Forge_APIRef-FrameAPIModelSceneFrameShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPIModelSceneFrameShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPINamePlate\Forge_APIRef-FrameAPINamePlate.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPINamePlate Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPIQuestPOI\Forge_APIRef-FrameAPIQuestPOI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPIQuestPOI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPIScenarioPOI\Forge_APIRef-FrameAPIScenarioPOI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPIScenarioPOI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPISimpleCheckout\Forge_APIRef-FrameAPISimpleCheckout.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPISimpleCheckout Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPITabardModel\Forge_APIRef-FrameAPITabardModel.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPITabardModel Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPITabardModelBase\Forge_APIRef-FrameAPITabardModelBase.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPITabardModelBase Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPITooltip\Forge_APIRef-FrameAPITooltip.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPITooltip Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameAPIUnitPositionFrame\Forge_APIRef-FrameAPIUnitPositionFrame.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameAPIUnitPositionFrame Version' },
    @{ Path = 'SubAddons\Forge_APIRef-FrameScript\Forge_APIRef-FrameScript.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-FrameScript Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GARRISON_FOLLOWER_TYPEConstants\Forge_APIRef-GARRISON_FOLLOWER_TYPEConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GARRISON_FOLLOWER_TYPEConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GARRISON_TYPEConstants\Forge_APIRef-GARRISON_TYPEConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GARRISON_TYPEConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GameCursor\Forge_APIRef-GameCursor.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GameCursor Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GameError\Forge_APIRef-GameError.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GameError Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GamePadConst\Forge_APIRef-GamePadConst.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GamePadConst Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GameRulesConstants\Forge_APIRef-GameRulesConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GameRulesConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GameUI\Forge_APIRef-GameUI.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GameUI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GarrisonConstants\Forge_APIRef-GarrisonConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GarrisonConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GarrisonShared\Forge_APIRef-GarrisonShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GarrisonShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GlyphConstants\Forge_APIRef-GlyphConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GlyphConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GossipConstants\Forge_APIRef-GossipConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GossipConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GroupFinderConstants\Forge_APIRef-GroupFinderConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GroupFinderConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GuildConstants\Forge_APIRef-GuildConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GuildConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-GuildInfoShared\Forge_APIRef-GuildInfoShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-GuildInfoShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-HouseExteriorConstants\Forge_APIRef-HouseExteriorConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-HouseExteriorConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-HousingCatalogConstants\Forge_APIRef-HousingCatalogConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-HousingCatalogConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-HousingCatalogSearcherAPI\Forge_APIRef-HousingCatalogSearcherAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-HousingCatalogSearcherAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-HousingDecorShared\Forge_APIRef-HousingDecorShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-HousingDecorShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-HousingFixturePointFrameAPI\Forge_APIRef-HousingFixturePointFrameAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-HousingFixturePointFrameAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-HousingLayoutPinFrameAPI\Forge_APIRef-HousingLayoutPinFrameAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-HousingLayoutPinFrameAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-HousingLayoutUITypes\Forge_APIRef-HousingLayoutUITypes.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-HousingLayoutUITypes Version' },
    @{ Path = 'SubAddons\Forge_APIRef-HousingUIShared\Forge_APIRef-HousingUIShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-HousingUIShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ImageSharingConstants\Forge_APIRef-ImageSharingConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ImageSharingConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Input\Forge_APIRef-Input.toc';    Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Input Version' },
    @{ Path = 'SubAddons\Forge_APIRef-InputConstants\Forge_APIRef-InputConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-InputConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Instance\Forge_APIRef-Instance.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Instance Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ItemConstants\Forge_APIRef-ItemConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ItemConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ItemConstants_Mainline\Forge_APIRef-ItemConstants_Mainline.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ItemConstants_Mainline Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ItemConstants_Shared\Forge_APIRef-ItemConstants_Shared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ItemConstants_Shared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ItemQualities\Forge_APIRef-ItemQualities.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ItemQualities Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ItemShared\Forge_APIRef-ItemShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ItemShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LFGConstants\Forge_APIRef-LFGConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LFGConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LegendaryCraftingTypes\Forge_APIRef-LegendaryCraftingTypes.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LegendaryCraftingTypes Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LevelConstants\Forge_APIRef-LevelConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LevelConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Locale\Forge_APIRef-Locale.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Locale Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Localization\Forge_APIRef-Localization.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Localization Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LocalizationShared\Forge_APIRef-LocalizationShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LocalizationShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LogConstants\Forge_APIRef-LogConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LogConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LogicConstants\Forge_APIRef-LogicConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LogicConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LootConstants\Forge_APIRef-LootConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LootConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LuaColorCurveObjectAPI\Forge_APIRef-LuaColorCurveObjectAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LuaColorCurveObjectAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LuaCurveObjectAPI\Forge_APIRef-LuaCurveObjectAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LuaCurveObjectAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LuaCurveObjectBaseAPI\Forge_APIRef-LuaCurveObjectBaseAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LuaCurveObjectBaseAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LuaCurveObjectConstants\Forge_APIRef-LuaCurveObjectConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LuaCurveObjectConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LuaDurationObjectAPI\Forge_APIRef-LuaDurationObjectAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LuaDurationObjectAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-LuaDurationObjectShared\Forge_APIRef-LuaDurationObjectShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-LuaDurationObjectShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-MajorFactionsConstants\Forge_APIRef-MajorFactionsConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-MajorFactionsConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-MapConstants\Forge_APIRef-MapConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-MapConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-MatrixShared\Forge_APIRef-MatrixShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-MatrixShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-MinimapConstants\Forge_APIRef-MinimapConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-MinimapConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-MinimapFrameAPI\Forge_APIRef-MinimapFrameAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-MinimapFrameAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-MirrorTimer\Forge_APIRef-MirrorTimer.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-MirrorTimer Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ModelAnimationShared\Forge_APIRef-ModelAnimationShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ModelAnimationShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-MoneyConstants\Forge_APIRef-MoneyConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-MoneyConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-MountConstants\Forge_APIRef-MountConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-MountConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Movie\Forge_APIRef-Movie.toc';    Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Movie Version' },
    @{ Path = 'SubAddons\Forge_APIRef-MythicPlusInfoShared\Forge_APIRef-MythicPlusInfoShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-MythicPlusInfoShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-NamePlateConstants\Forge_APIRef-NamePlateConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-NamePlateConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-NeighborhoodInitiativesConstants\Forge_APIRef-NeighborhoodInitiativesConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-NeighborhoodInitiativesConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-NumericFormatterAPI\Forge_APIRef-NumericFormatterAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-NumericFormatterAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-NumericRuleFormatterAPI\Forge_APIRef-NumericRuleFormatterAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-NumericRuleFormatterAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-NumericRuleFormatterShared\Forge_APIRef-NumericRuleFormatterShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-NumericRuleFormatterShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Os\Forge_APIRef-Os.toc';          Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Os Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PVPMgrConstants\Forge_APIRef-PVPMgrConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PVPMgrConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ParentalControls\Forge_APIRef-ParentalControls.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ParentalControls Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PartyConstants\Forge_APIRef-PartyConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PartyConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PartyPoseUIConstants\Forge_APIRef-PartyPoseUIConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PartyPoseUIConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PerformanceScript\Forge_APIRef-PerformanceScript.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PerformanceScript Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PerksVendorConstants\Forge_APIRef-PerksVendorConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PerksVendorConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PetBattleConstants\Forge_APIRef-PetBattleConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PetBattleConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PetScalingConstants\Forge_APIRef-PetScalingConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PetScalingConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PingConstants\Forge_APIRef-PingConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PingConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PingPinFrameAPI\Forge_APIRef-PingPinFrameAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PingPinFrameAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Player\Forge_APIRef-Player.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Player Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PlayerDataConstants\Forge_APIRef-PlayerDataConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PlayerDataConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PlayerHousingConstants\Forge_APIRef-PlayerHousingConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PlayerHousingConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PlayerInfoShared\Forge_APIRef-PlayerInfoShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PlayerInfoShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PlayerInteractionManagerConstants\Forge_APIRef-PlayerInteractionManagerConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PlayerInteractionManagerConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PlayerMentorshipConstants\Forge_APIRef-PlayerMentorshipConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PlayerMentorshipConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PlayerScript\Forge_APIRef-PlayerScript.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PlayerScript Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PowerTypeConstants\Forge_APIRef-PowerTypeConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PowerTypeConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ProceduralSpawnConstants\Forge_APIRef-ProceduralSpawnConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ProceduralSpawnConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ProfessionConstants\Forge_APIRef-ProfessionConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ProfessionConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ProfessionSpecConstants\Forge_APIRef-ProfessionSpecConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ProfessionSpecConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PvPFactionConstants\Forge_APIRef-PvPFactionConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PvPFactionConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-PvpInfoConstants\Forge_APIRef-PvpInfoConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-PvpInfoConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-QuestConstants\Forge_APIRef-QuestConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-QuestConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-QuestConstants_Mainline\Forge_APIRef-QuestConstants_Mainline.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-QuestConstants_Mainline Version' },
    @{ Path = 'SubAddons\Forge_APIRef-QuestInfoShared\Forge_APIRef-QuestInfoShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-QuestInfoShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-QuestRewards\Forge_APIRef-QuestRewards.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-QuestRewards Version' },
    @{ Path = 'SubAddons\Forge_APIRef-QuestSessionConstants\Forge_APIRef-QuestSessionConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-QuestSessionConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-QueueSpecific\Forge_APIRef-QueueSpecific.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-QueueSpecific Version' },
    @{ Path = 'SubAddons\Forge_APIRef-RaidMarkers\Forge_APIRef-RaidMarkers.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-RaidMarkers Version' },
    @{ Path = 'SubAddons\Forge_APIRef-RecentAlliesConstants\Forge_APIRef-RecentAlliesConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-RecentAlliesConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-RecruitAFriendShared\Forge_APIRef-RecruitAFriendShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-RecruitAFriendShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-RenownConstants\Forge_APIRef-RenownConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-RenownConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ReportSystemConstants\Forge_APIRef-ReportSystemConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ReportSystemConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-RestrictedActionsConstants\Forge_APIRef-RestrictedActionsConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-RestrictedActionsConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-RolodexConstants\Forge_APIRef-RolodexConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-RolodexConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Screen\Forge_APIRef-Screen.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Screen Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ScreenLocationConstants\Forge_APIRef-ScreenLocationConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ScreenLocationConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SeasonsConstants\Forge_APIRef-SeasonsConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SeasonsConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SecondsFormatterAPI\Forge_APIRef-SecondsFormatterAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SecondsFormatterAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SecondsFormatterShared\Forge_APIRef-SecondsFormatterShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SecondsFormatterShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SecretAspectConstants\Forge_APIRef-SecretAspectConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SecretAspectConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SecretPredicates\Forge_APIRef-SecretPredicates.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SecretPredicates Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SecretWrapperConstants\Forge_APIRef-SecretWrapperConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SecretWrapperConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SharedScriptObjectModelLight\Forge_APIRef-SharedScriptObjectModelLight.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SharedScriptObjectModelLight Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SharedScriptObjectNamePlateFrame\Forge_APIRef-SharedScriptObjectNamePlateFrame.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SharedScriptObjectNamePlateFrame Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SharedScriptObjectUnitPositionFrame\Forge_APIRef-SharedScriptObjectUnitPositionFrame.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SharedScriptObjectUnitPositionFrame Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SharedTraitsEnums\Forge_APIRef-SharedTraitsEnums.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SharedTraitsEnums Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimAPI\Forge_APIRef-SimpleAnimAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimAlphaAPI\Forge_APIRef-SimpleAnimAlphaAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimAlphaAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimFlipBookAPI\Forge_APIRef-SimpleAnimFlipBookAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimFlipBookAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimGroupAPI\Forge_APIRef-SimpleAnimGroupAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimGroupAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimPathAPI\Forge_APIRef-SimpleAnimPathAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimPathAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimRotationAPI\Forge_APIRef-SimpleAnimRotationAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimRotationAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimScaleAPI\Forge_APIRef-SimpleAnimScaleAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimScaleAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimScaleLineAPI\Forge_APIRef-SimpleAnimScaleLineAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimScaleLineAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimTextureCoordTranslationAPI\Forge_APIRef-SimpleAnimTextureCoordTranslationAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimTextureCoordTranslationAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimTranslationAPI\Forge_APIRef-SimpleAnimTranslationAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimTranslationAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimTranslationLineAPI\Forge_APIRef-SimpleAnimTranslationLineAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimTranslationLineAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimVertexColorAPI\Forge_APIRef-SimpleAnimVertexColorAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimVertexColorAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleAnimatableObjectAPI\Forge_APIRef-SimpleAnimatableObjectAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleAnimatableObjectAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleBrowserAPI\Forge_APIRef-SimpleBrowserAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleBrowserAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleButtonAPI\Forge_APIRef-SimpleButtonAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleButtonAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleCheckboxAPI\Forge_APIRef-SimpleCheckboxAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleCheckboxAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleColorSelectAPI\Forge_APIRef-SimpleColorSelectAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleColorSelectAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleControlPointAPI\Forge_APIRef-SimpleControlPointAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleControlPointAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleEditBoxAPI\Forge_APIRef-SimpleEditBoxAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleEditBoxAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleFontAPI\Forge_APIRef-SimpleFontAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleFontAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleFontStringAPI\Forge_APIRef-SimpleFontStringAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleFontStringAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleFrameAPI\Forge_APIRef-SimpleFrameAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleFrameAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleFrameScriptObjectAPI\Forge_APIRef-SimpleFrameScriptObjectAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleFrameScriptObjectAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleHTMLAPI\Forge_APIRef-SimpleHTMLAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleHTMLAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleHTMLShared\Forge_APIRef-SimpleHTMLShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleHTMLShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleLineAPI\Forge_APIRef-SimpleLineAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleLineAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleMapSceneAPI\Forge_APIRef-SimpleMapSceneAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleMapSceneAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleMaskTextureAPI\Forge_APIRef-SimpleMaskTextureAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleMaskTextureAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleMessageFrameAPI\Forge_APIRef-SimpleMessageFrameAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleMessageFrameAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleModelAPI\Forge_APIRef-SimpleModelAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleModelAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleModelFFXAPI\Forge_APIRef-SimpleModelFFXAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleModelFFXAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleMovieAPI\Forge_APIRef-SimpleMovieAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleMovieAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleObjectAPI\Forge_APIRef-SimpleObjectAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleObjectAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleOffScreenFrameAPI\Forge_APIRef-SimpleOffScreenFrameAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleOffScreenFrameAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleRegionAPI\Forge_APIRef-SimpleRegionAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleRegionAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleScriptRegionAPI\Forge_APIRef-SimpleScriptRegionAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleScriptRegionAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleScriptRegionResizingAPI\Forge_APIRef-SimpleScriptRegionResizingAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleScriptRegionResizingAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleScrollFrameAPI\Forge_APIRef-SimpleScrollFrameAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleScrollFrameAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleSliderAPI\Forge_APIRef-SimpleSliderAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleSliderAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleStatusBarAPI\Forge_APIRef-SimpleStatusBarAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleStatusBarAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleStatusBarConstants\Forge_APIRef-SimpleStatusBarConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleStatusBarConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleTextureAPI\Forge_APIRef-SimpleTextureAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleTextureAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SimpleTextureBaseAPI\Forge_APIRef-SimpleTextureBaseAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SimpleTextureBaseAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SlashCommand\Forge_APIRef-SlashCommand.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SlashCommand Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SocialConstants\Forge_APIRef-SocialConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SocialConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SoftTargetConstants\Forge_APIRef-SoftTargetConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SoftTargetConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SoulbindsConstants\Forge_APIRef-SoulbindsConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SoulbindsConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SpecializationShared\Forge_APIRef-SpecializationShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SpecializationShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SpellBookConstants\Forge_APIRef-SpellBookConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SpellBookConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SpellConstants\Forge_APIRef-SpellConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SpellConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SpellDiminishConstants\Forge_APIRef-SpellDiminishConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SpellDiminishConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SpellID\Forge_APIRef-SpellID.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SpellID Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SpellShared\Forge_APIRef-SpellShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SpellShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SplashScreenConstants\Forge_APIRef-SplashScreenConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SplashScreenConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Streaming\Forge_APIRef-Streaming.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Streaming Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SummonConstants\Forge_APIRef-SummonConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SummonConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SuperTrackManagerShared\Forge_APIRef-SuperTrackManagerShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SuperTrackManagerShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-SystemTime\Forge_APIRef-SystemTime.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-SystemTime Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TalentAndGlyphConstants\Forge_APIRef-TalentAndGlyphConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TalentAndGlyphConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TalentConstants\Forge_APIRef-TalentConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TalentConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TargetScript\Forge_APIRef-TargetScript.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TargetScript Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TextureShared\Forge_APIRef-TextureShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TextureShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Threat\Forge_APIRef-Threat.toc';  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Threat Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Time\Forge_APIRef-Time.toc';      Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Time Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TimerConstants\Forge_APIRef-TimerConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TimerConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TimerunningConstants\Forge_APIRef-TimerunningConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TimerunningConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Title\Forge_APIRef-Title.toc';    Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Title Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TooltipConstants\Forge_APIRef-TooltipConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TooltipConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TooltipInfoShared\Forge_APIRef-TooltipInfoShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TooltipInfoShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Totem\Forge_APIRef-Totem.toc';    Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Totem Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TradeSkillUITypes\Forge_APIRef-TradeSkillUITypes.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TradeSkillUITypes Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TraitConstants\Forge_APIRef-TraitConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TraitConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TransformManipulatorConstants\Forge_APIRef-TransformManipulatorConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TransformManipulatorConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TransmogConstants\Forge_APIRef-TransmogConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TransmogConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TransmogOutfitConstants\Forge_APIRef-TransmogOutfitConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TransmogOutfitConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-TransmogShared\Forge_APIRef-TransmogShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-TransmogShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UIActionConstants\Forge_APIRef-UIActionConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UIActionConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UIButtonShared\Forge_APIRef-UIButtonShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UIButtonShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UICharacterClassConstants\Forge_APIRef-UICharacterClassConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UICharacterClassConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UIColorShared\Forge_APIRef-UIColorShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UIColorShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UICovenantDisplayInfoConstants\Forge_APIRef-UICovenantDisplayInfoConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UICovenantDisplayInfoConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UIEventToastConstants\Forge_APIRef-UIEventToastConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UIEventToastConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UIFileAssetShared\Forge_APIRef-UIFileAssetShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UIFileAssetShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UIMapPinShared\Forge_APIRef-UIMapPinShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UIMapPinShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UIModelInfoShared\Forge_APIRef-UIModelInfoShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UIModelInfoShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UIShared\Forge_APIRef-UIShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UIShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UITextureAssetShared\Forge_APIRef-UITextureAssetShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UITextureAssetShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UITextureConstants\Forge_APIRef-UITextureConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UITextureConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UIWidgetManagerShared\Forge_APIRef-UIWidgetManagerShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UIWidgetManagerShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-URL\Forge_APIRef-URL.toc';        Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-URL Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UiModelSceneConstants\Forge_APIRef-UiModelSceneConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UiModelSceneConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UiRpcRequestManagerConstants\Forge_APIRef-UiRpcRequestManagerConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UiRpcRequestManagerConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-Unit\Forge_APIRef-Unit.toc';      Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-Unit Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UnitAuraShared\Forge_APIRef-UnitAuraShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UnitAuraShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UnitConstants\Forge_APIRef-UnitConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UnitConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UnitHealPredictionCalculatorAPI\Forge_APIRef-UnitHealPredictionCalculatorAPI.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UnitHealPredictionCalculatorAPI Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UnitHealPredictionCalculatorShared\Forge_APIRef-UnitHealPredictionCalculatorShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UnitHealPredictionCalculatorShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UnitRole\Forge_APIRef-UnitRole.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UnitRole Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UnitSexConstants\Forge_APIRef-UnitSexConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UnitSexConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-UnitShared\Forge_APIRef-UnitShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-UnitShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ValidateNameConstants\Forge_APIRef-ValidateNameConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ValidateNameConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-VectorShared\Forge_APIRef-VectorShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-VectorShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-VignetteConstants\Forge_APIRef-VignetteConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-VignetteConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-WarbandSceneInfoConstants\Forge_APIRef-WarbandSceneInfoConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-WarbandSceneInfoConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-WeeklyRewardsShared\Forge_APIRef-WeeklyRewardsShared.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-WeeklyRewardsShared Version' },
    @{ Path = 'SubAddons\Forge_APIRef-WorldElapsedTimerConstants\Forge_APIRef-WorldElapsedTimerConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-WorldElapsedTimerConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-WowCSConstants\Forge_APIRef-WowCSConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-WowCSConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-WowSurveyConstants\Forge_APIRef-WowSurveyConstants.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-WowSurveyConstants Version' },
    @{ Path = 'SubAddons\Forge_APIRef-ZoneScript\Forge_APIRef-ZoneScript.toc';Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_APIRef-ZoneScript Version' },
    @{ Path = 'SubAddons\Forge_AddonManager\Forge_AddonManager.toc';    Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_AddonManager Version' },
    @{ Path = 'SubAddons\Forge_BugCatcher\Forge_BugCatcher.toc';        Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_BugCatcher Version' },
    @{ Path = 'SubAddons\Forge_CVars\Forge_CVars.toc';                  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_CVars Version' },
    @{ Path = 'SubAddons\Forge_Codex\Forge_Codex.toc';                  Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Codex Version' },
    @{ Path = 'SubAddons\Forge_Console\Forge_Console.toc';              Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Console Version' },
    @{ Path = 'SubAddons\Forge_Inspector\Forge_Inspector.toc';          Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Inspector Version' },
    @{ Path = 'SubAddons\Forge_Logs\Forge_Logs.toc';                    Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Logs Version' },
    @{ Path = 'SubAddons\Forge_Macros\Forge_Macros.toc';                Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Macros Version' },
    @{ Path = 'SubAddons\Forge_Profiles\Forge_Profiles.toc';            Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Profiles Version' },
    @{ Path = 'SubAddons\Forge_Registry\Forge_Registry.toc';            Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Registry Version' }
)

# --------------------------------------------------------------------------

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Args)
    & git @Args
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Args -join ' ') failed (exit $LASTEXITCODE)"
    }
}

# This script lives at .dev/release.ps1; the repo root is one level up.
# Anchor there so $FilesToBump's relative paths (Forge.toc, Forge_*/*.toc)
# resolve correctly no matter where the user invoked this from.
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {
    # Read the current version from the primary TOC and increment by 1.
    if (-not (Test-Path $PrimaryVersionFile)) {
        throw "Primary version file not found: $PrimaryVersionFile"
    }
    $primaryContent = Get-Content $PrimaryVersionFile -Raw
    if ($primaryContent -match '(?m)^## Version:\s*(\d+)') {
        $currentVersion = [long]$matches[1]
    } else {
        $currentVersion = 0
    }
    $stamp = ($currentVersion + 1).ToString()

    Write-Host ''
    Write-Host "Release $AddonName -> $stamp" -ForegroundColor Cyan
    Write-Host "Commit message: $Message"     -ForegroundColor Cyan
    Write-Host ''

    foreach ($entry in $FilesToBump) {
        if (-not (Test-Path $entry.Path)) {
            throw "Missing file: $($entry.Path)"
        }
        $content = Get-Content $entry.Path -Raw
        $matches = [regex]::Matches($content, $entry.Pattern)
        if ($matches.Count -eq 0) {
            throw "Pattern not found in $($entry.Path): $($entry.Pattern)"
        }
        if ($matches.Count -gt 1) {
            throw "Pattern matched $($matches.Count) places in $($entry.Path); expected exactly 1."
        }
        $oldLine = $matches[0].Value
        $newLine = $matches[0].Groups[1].Value + $stamp
        Write-Host "  $($entry.Description) [$($entry.Path)]"
        Write-Host "    before: $oldLine"
        Write-Host "    after:  $newLine"
    }
    Write-Host ''

    if ($DryRun) {
        Write-Host 'DRY RUN. No files modified, no git actions.' -ForegroundColor Yellow
        return
    }

    foreach ($entry in $FilesToBump) {
        $content = Get-Content $entry.Path -Raw
        $updated = [regex]::Replace($content, $entry.Pattern, '${1}' + $stamp)
        Set-Content -Path $entry.Path -Value $updated -NoNewline
    }
    Write-Host 'Files updated.' -ForegroundColor Green
    Write-Host ''

    Invoke-Git @('add', '-A')
    Invoke-Git @('commit', '-m', $Message)

    Invoke-Git @('tag', '-a', $stamp, '-m', $stamp)

    if ($NoPush) {
        Write-Host "Tagged $stamp locally. Skipping push (-NoPush)." -ForegroundColor Yellow
    } else {
        Invoke-Git @('push', 'origin', 'HEAD')
        Invoke-Git @('push', 'origin', $stamp)
        Write-Host ''
        Write-Host "Released $stamp." -ForegroundColor Green
        Write-Host "GitHub Actions: https://github.com/$RepoOwner/$AddonName/actions" -ForegroundColor Cyan
    }
}
catch {
    Write-Host "Release failed: $_" -ForegroundColor Red
    exit 1
}
finally {
    Pop-Location
}
