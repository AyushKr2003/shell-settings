import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "./components" as Cmp

Item {
  id: root

  // ---------------- plugin lifecycle ---------------------------------------
  property bool closingFromHost: false

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    Qt.callLater(parkFocusOnSink)
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  // ---------------- host injections ----------------------------------------
  property var barWidgetRegistry: null
  property var pluginRegistry: null
  property var shell: null
  property var manifest: null

  // ---------------- paths --------------------------------------------------
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string home: Quickshell.env("HOME")
  readonly property string userConfigPath: home + "/.config/omarchy/shell.json"
  readonly property string defaultsPath: omarchyPath + "/config/omarchy/shell.json"

  // ---------------- theme --------------------------------------------------
  // Settings deliberately isn't a themable surface in shell.toml — it
  // tracks the foundational palette so every theme renders consistently.
  property color foreground: Commons.Color.popups.text
  property color background: Commons.Color.popups.background
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property string fontFamily: "monospace"

  // Structural style tokens live on the shared Style singleton so theme swaps
  // and Hyprland-derived values update every consumer at once.
  // Aliasing them as readonly properties keeps the existing inline component
  // bindings (`root.cornerRadius`, `root.focusBorderColor`, ...) working
  // without sprinkling Style.* across the file.
  readonly property int cornerRadius: Style.cornerRadius
  readonly property color focusBorderColor: Style.focusBorderColor
  readonly property color focusFillColor: Style.focusFillColor
  readonly property int focusBorderWidth: Style.focusBorderWidth

  // Move activeFocus to a dedicated sink Item that lives outside the body
  // tree. Just clearing focus on the previously focused descendant isn't
  // enough — controls like ComboBox keep an internal focused child that
  // FocusScope happily restores. Forcing focus onto a known sink reliably
  // clears every body focus ring.
  function parkFocusOnSink() {
    if (typeof navFocusSink !== "undefined" && navFocusSink) navFocusSink.forceActiveFocus()
    else if (navRoot) navRoot.forceActiveFocus()
  }

  // Walk the visible body subtree and collect any item with
  // `activeFocusOnTab: true` so j/k can move through the form.
  function gatherBodyFocusables() {
    var arr = []
    function walk(item) {
      if (!item || !item.visible || item.enabled === false) return
      if (item.activeFocusOnTab === true) arr.push(item)
      var children = item.children
      if (!children) return
      for (var i = 0; i < children.length; i++) walk(children[i])
    }
    if (typeof bodyScroll !== "undefined" && bodyScroll && bodyScroll.contentItem)
      walk(bodyScroll.contentItem)
    return arr
  }

  function focusFirstBodyItem() {
    var items = gatherBodyFocusables()
    if (items.length > 0) {
      items[0].forceActiveFocus()
      ensureBodyItemVisible(items[0])
    } else if (navRoot) {
      navRoot.forceActiveFocus()
    }
  }

  function focusBodyDelta(delta) {
    var items = gatherBodyFocusables()
    if (items.length === 0) { parkFocusOnSink(); return }
    var current = -1
    for (var i = 0; i < items.length; i++) {
      if (items[i].activeFocus) { current = i; break }
    }
    var next = current < 0 ? 0 : current + delta
    if (next < 0) next = items.length - 1
    if (next >= items.length) next = 0
    items[next].forceActiveFocus()
    ensureBodyItemVisible(items[next])
  }

  // Scroll the bodyScroll Flickable so `item` is fully on-screen, with a
  // little padding above/below.
  function ensureBodyItemVisible(item) {
    if (!item || typeof bodyScroll === "undefined" || !bodyScroll || !bodyScroll.contentItem) return
    var pos = item.mapToItem(bodyScroll.contentItem, 0, 0)
    var pad = Style.space(24)
    var top = pos.y - pad
    var bottom = pos.y + item.height + pad
    if (top < bodyScroll.contentY) {
      bodyScroll.contentY = Math.max(0, top)
    } else if (bottom > bodyScroll.contentY + bodyScroll.height) {
      var maxY = Math.max(0, bodyScroll.contentHeight - bodyScroll.height)
      bodyScroll.contentY = Math.min(maxY, bottom - bodyScroll.height)
    }
  }

  // ---------------- bundled defaults ---------------------------------------
  readonly property var builtinShellConfig: ({
    version: 1,
    idle: {
      screensaver: 150,
      lock: 300
    },
    bar: {
      position: "top",
      transparent: false,
      centerAnchor: "omarchy.clock",
      layout: {
        left: [{ id: "omarchy.menu" }, { id: "omarchy.workspaces" }],
        center: [
          { id: "omarchy.clock", format: "dddd HH:mm", formatAlt: "dd MMMM 'W'ww yyyy", verticalFormat: "HH\n\u2014\nmm" },
          { id: "omarchy.weather" }, { id: "omarchy.system-update" }, { id: "omarchy.indicators" }
        ],
        right: [
          { id: "omarchy.tray" }, { id: "omarchy.bluetooth" }, { id: "omarchy.network" },
          { id: "omarchy.audio" }, { id: "omarchy.monitor" }, { id: "omarchy.power" }
        ]
      }
    },
    plugins: []
  })

  property var defaultConfig: builtinShellConfig
  property var draft: ({
    version: 1,
    idle: { screensaver: 150, lock: 300 },
    bar: { position: "top", transparent: false, centerAnchor: "omarchy.clock", layout: { left: [], center: [], right: [] } },
    plugins: []
  })
  property int draftRevision: 0
  property int pluginRevision: 0
  property bool suppressReload: false
  property string localPluginStatus: ""
  property string onlineInstallStatus: ""
  property string pendingEnablePluginId: ""
  property string pluginFilter: "Third-party"
  property var lastValidUserConfig: null
  property bool userConfigLoaded: false
  property bool draftLoaded: false

  // When a widget action moves an entry, the Repeater rebuilds / reindexes
  // cards. Remember the action group position so focus follows the moved
  // widget instead of falling back to the first action on the old/new row.
  property string pendingActionFocusSection: ""
  property int pendingActionFocusIndex: -1
  property int pendingActionFocusAction: 0
  property int pendingActionFocusRevision: 0

  function scheduleActionFocus(section, index, action) {
    pendingActionFocusSection = section
    pendingActionFocusIndex = index
    pendingActionFocusAction = action
    pendingActionFocusRevision++
  }

  function clearPendingActionFocus() {
    pendingActionFocusSection = ""
    pendingActionFocusIndex = -1
    pendingActionFocusAction = 0
  }

  // ---------------- draft helpers ------------------------------------------
  function secondsFromConfig(value, fallback) {
    var parsed = parseInt(value, 10)
    if (isNaN(parsed)) return fallback
    return Math.max(0, Math.min(86400, parsed))
  }

  function validShellConfig(value) {
    return Util.isPlainObject(value) && value.version === 1
  }

  function parseShellConfigText(raw) {
    var text = String(raw || "").trim()
    if (!text) return null
    try {
      var parsed = JSON.parse(text)
      return validShellConfig(parsed) ? parsed : null
    } catch (e) {
      console.warn("shell.settings: shell.json parse failed: " + e)
      return null
    }
  }

  function rememberUserConfig(raw) {
    userConfigLoaded = true
    var parsed = parseShellConfigText(raw)
    if (parsed) lastValidUserConfig = parsed
    if (!suppressReload) Qt.callLater(loadConfig)
  }

  function normalizeDraft(source) {
    var idle = Util.isPlainObject(source.idle) ? source.idle : {}
    var bar = Util.isPlainObject(source.bar) ? source.bar : {}
    var plugins = Array.isArray(source.plugins) ? source.plugins.slice() : []
    return {
      version: 1,
      idle: {
        screensaver: secondsFromConfig(idle.screensaver, builtinShellConfig.idle.screensaver),
        lock: secondsFromConfig(idle.lock, builtinShellConfig.idle.lock)
      },
      bar: {
        position: String(bar.position || "top"),
        transparent: bar.transparent === true,
        centerAnchor: Util.canonicalWidgetId(bar.centerAnchor || ""),
        layout: Util.normalizeLayout(bar.layout || {})
      },
      plugins: plugins
        .map(Util.normalizeLayoutEntry)
        .filter(function(e) {
          if (!e) return false
          var manifest = root.pluginRegistry ? root.pluginRegistry.installedPlugins[e.id] : null
          if (manifest && manifest.__isFirstParty) return false
          return true
        })
    }
  }

  function loadConfig() {
    var defaults = shell && validShellConfig(shell.defaultsConfig)
      ? shell.defaultsConfig
      : builtinShellConfig
    defaultConfig = defaults

    var source = lastValidUserConfig && validShellConfig(lastValidUserConfig)
      ? lastValidUserConfig
      : (shell && validShellConfig(shell.shellConfig) ? shell.shellConfig : defaults)
    draft = normalizeDraft(source)
    draftLoaded = true
    draftRevision++
  }

  function persistDraft() {
    if (!userConfigLoaded) {
      console.warn("shell.settings: refusing to persist before user shell.json has been checked")
      return
    }
    if (!draftLoaded) {
      console.warn("shell.settings: refusing to persist before shell.json has been loaded")
      return
    }
    suppressReload = true
    if (shell && typeof shell.mutateShellConfig === "function") {
      var nextDraft = Util.cloneJson(draft)
      var baseConfig = lastValidUserConfig && validShellConfig(lastValidUserConfig)
        ? Util.cloneJson(lastValidUserConfig)
        : (shell && validShellConfig(shell.shellConfig) ? Util.cloneJson(shell.shellConfig) : null)
      if (!baseConfig) {
        console.warn("shell.settings: refusing to persist without a valid shell.json base")
        suppressReload = false
        return
      }
      shell.mutateShellConfig(function(config) {
        baseConfig.version = 1
        baseConfig.idle = Util.cloneJson(nextDraft.idle)
        baseConfig.bar = Util.cloneJson(nextDraft.bar)
        baseConfig.plugins = Util.cloneJson(nextDraft.plugins || [])
        for (var key in config) delete config[key]
        for (var nextKey in baseConfig) config[nextKey] = Util.cloneJson(baseConfig[nextKey])
      })
      lastValidUserConfig = Util.cloneJson(baseConfig)
      Qt.callLater(function() { suppressReload = false })
    } else {
      console.warn("shell.settings: shell.mutateShellConfig is unavailable; cannot persist settings")
      suppressReload = false
    }
  }

  function defaultBarDraft() {
    var source = defaultConfig
    if (!Util.isPlainObject(source) || !Util.isPlainObject(source.bar) || !Util.isPlainObject(source.bar.layout)) {
      source = builtinShellConfig
    } else {
      var l = source.bar.layout
      var anyEntries = (l.left && l.left.length) || (l.center && l.center.length) || (l.right && l.right.length)
      if (!anyEntries) source = builtinShellConfig
    }
    return normalizeDraft(source).bar
  }

  function resetBarToDefaults() {
    var next = Util.cloneJson(draft)
    next.bar = Util.cloneJson(defaultBarDraft())
    draft = next
    draftRevision++
    persistDraft()
  }

  function markDirty() {
    draftRevision++
    persistDraft()
  }

  function updateIdle(key, value) {
    var next = Util.cloneJson(draft)
    if (!Util.isPlainObject(next.idle)) next.idle = {}
    next.idle[key] = secondsFromConfig(value, key === "screensaver" ? 150 : 300)
    draft = next
    markDirty()
  }

  function sectionArray(section) {
    if (section === "plugins") return draft.plugins || []
    return (draft.bar && draft.bar.layout && draft.bar.layout[section]) || []
  }

  function mutateSection(section, mutator) {
    var arr = sectionArray(section).slice()
    mutator(arr)
    var nextDraft = Util.cloneJson(draft)
    if (section === "plugins") nextDraft.plugins = arr
    else nextDraft.bar.layout[section] = arr
    draft = nextDraft
    markDirty()
  }

  function moveEntry(section, fromIndex, toIndex, focusActionIndex) {
    var arr = sectionArray(section)
    if (toIndex < 0 || toIndex >= arr.length) return
    mutateSection(section, function(a) {
      var item = a[fromIndex]
      a.splice(fromIndex, 1)
      a.splice(toIndex, 0, item)
    })
    if (focusActionIndex !== undefined) scheduleActionFocus(section, toIndex, focusActionIndex)
  }

  function removeEntry(section, index) {
    mutateSection(section, function(a) { a.splice(index, 1) })
  }

  function defaultEntryForWidget(id) {
    var bar = defaultBarDraft()
    var layout = bar && bar.layout ? bar.layout : {}
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]] || []
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].id === id) return Util.cloneJson(entries[i])
      }
    }
    return { id: id }
  }

  function addEntry(section, id) {
    mutateSection(section, function(a) { a.push(defaultEntryForWidget(id)) })
  }

  function updateEntry(section, index, newEntry) {
    mutateSection(section, function(a) { a[index] = Util.cloneJson(newEntry) })
  }

  function findEntryLocation(id) {
    var key = canonicalWidgetId(id)
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = sectionArray(sections[s])
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && canonicalWidgetId(entries[i].id) === key)
          return { found: true, section: sections[s], index: i, entry: entries[i], kind: "bar" }
      }
    }

    var plugins = sectionArray("plugins")
    for (var p = 0; p < plugins.length; p++) {
      if (plugins[p] && canonicalWidgetId(plugins[p].id) === key)
        return { found: true, section: "plugins", index: p, entry: plugins[p], kind: "plugin" }
    }
    return { found: false }
  }

  // ---------------- widget catalog -----------------------------------------
  property int catalogRevision: 0
  onBarWidgetRegistryChanged: {
    catalogRevision++
    if (!root.barWidgetRegistry) return
    console.log("bar settings panel open. omarchyPath=" + root.omarchyPath,
      "defaultsPath=" + root.defaultsPath,
      "userConfigPath=" + root.userConfigPath,
      "registry has",
      root.barWidgetRegistry.availableIds().length,
      "widgets")
  }
  Connections {
    target: root.barWidgetRegistry
    function onChanged() { root.catalogRevision++ }
  }

  Connections {
    target: root.pluginRegistry
    function onPluginsChanged() {
      root.pluginRevision++
      root.catalogRevision++
      if (root.pendingEnablePluginId
          && root.pluginRegistry.installedPlugins
          && root.pluginRegistry.installedPlugins[root.pendingEnablePluginId]) {
        root.setPluginEnabled(root.pendingEnablePluginId, true)
        root.localPluginStatus = "Installed and enabled " + root.pendingEnablePluginId
        root.pendingEnablePluginId = ""
      }
    }

  }

  Connections {
    target: root.shell
    ignoreUnknownSignals: true
    function onShellConfigChanged() {
      if (root.suppressReload) {
        root.suppressReload = false
        return
      }
      root.loadConfig()
    }
  }

  function canonicalWidgetId(id) {
    return Util.canonicalWidgetId(id)
  }

  function widgetMetadata(id) {
    var key = String(id || "")
    var canonicalKey = canonicalWidgetId(key)
    if (root.barWidgetRegistry && root.barWidgetRegistry.has(canonicalKey))
      return root.barWidgetRegistry.metadataFor(canonicalKey) || {}

    var manifest = root.pluginRegistry ? root.pluginRegistry.installedPlugins[key] : null
    if (manifest) {
      var meta = manifest.barWidget || {}
      return {
        displayName: meta.displayName || manifest.name || key,
        name: meta.displayName || manifest.name || key,
        description: meta.description || manifest.description || "",
        category: meta.category || "Plugin",
        allowMultiple: meta.allowMultiple === true,
        settingsForm: meta.settingsForm || "",
        schema: Array.isArray(meta.schema) ? meta.schema : [],
        sourceDir: manifest.__sourceDir || "",
        source: "plugin"
      }
    }
    return {}
  }

  function widgetSourceDir(id) {
    var meta = widgetMetadata(id)
    return meta && meta.sourceDir ? String(meta.sourceDir) : ""
  }

  function widgetName(id) {
    var rev = catalogRevision
    var meta = widgetMetadata(id)
    return meta.displayName || meta.name || id
  }

  function widgetDescription(id) {
    var rev = catalogRevision
    var meta = widgetMetadata(id)
    return meta.description || ""
  }

  function widgetSchema(id) {
    var meta = widgetMetadata(id)
    return Array.isArray(meta.schema) ? meta.schema : []
  }

  function widgetHasSettings(id) {
    var rev = catalogRevision
    var meta = widgetMetadata(id)
    if (meta.settingsForm) return true
    if (widgetSchema(id).length > 0) return true
    return false
  }

  function widgetAllowsMultiple(id) {
    var meta = widgetMetadata(id)
    if (meta.allowMultiple === true) return true
    return canonicalWidgetId(id) === "omarchy.spacer"
  }

  function catalogIds() {
    var rev = catalogRevision
    var ids = {}
    if (root.barWidgetRegistry) {
      var registered = root.barWidgetRegistry.availableIds()
      for (var i = 0; i < registered.length; i++) ids[registered[i]] = true
    }
    if (root.pluginRegistry && root.pluginRegistry.installedPlugins) {
      var plugins = root.pluginRegistry.installedPlugins
      for (var pid in plugins) {
        var manifest = plugins[pid]
        if (manifest && Array.isArray(manifest.kinds) && manifest.kinds.indexOf("bar-widget") !== -1)
          ids[pid] = true
      }
    }
    return Object.keys(ids)
  }

  function availableToAdd(section) {
    var rev = catalogRevision
    var barSections = ["left", "center", "right"]

    var existingInBar = {}
    for (var s = 0; s < barSections.length; s++) {
      var list = sectionArray(barSections[s])
      for (var i = 0; i < list.length; i++) existingInBar[list[i].id] = true
    }

    var ids = catalogIds().sort(function(a, b) { return widgetName(a).localeCompare(widgetName(b)) })

    var result = []
    for (var k = 0; k < ids.length; k++) {
      var id = ids[k]
      var meta = widgetMetadata(id)
      var manifest = root.pluginRegistry ? root.pluginRegistry.installedPlugins[id] : null
      var manifestIsBarWidget = manifest && Array.isArray(manifest.kinds) && manifest.kinds.indexOf("bar-widget") !== -1
      var isBarWidget = !!(meta && meta.source !== "plugin") || manifestIsBarWidget
      if (!isBarWidget) continue

      var inSection = sectionArray(section)
      var existsHere = false
      for (var x = 0; x < inSection.length; x++) if (inSection[x].id === id) { existsHere = true; break }
      var allowsMultiple = widgetAllowsMultiple(id)
      if (!allowsMultiple && existingInBar[id]) continue
      result.push({ id: id, name: widgetName(id), description: widgetDescription(id),
        elsewhere: allowsMultiple && !!existingInBar[id] && !existsHere })
    }
    return result
  }

  function pluginKindText(manifest) {
    return manifest && Array.isArray(manifest.kinds) ? manifest.kinds.join(", ") : ""
  }

  function pluginIsBarWidget(manifest) {
    return manifest && Array.isArray(manifest.kinds) && manifest.kinds.indexOf("bar-widget") !== -1
  }

  function pluginManifest(id) {
    return root.pluginRegistry && root.pluginRegistry.installedPlugins
      ? root.pluginRegistry.installedPlugins[String(id || "")]
      : null
  }

  function pluginEnabled(id) {
    return root.pluginRegistry && typeof root.pluginRegistry.isEnabled === "function"
      ? root.pluginRegistry.isEnabled(id)
      : false
  }

  function pluginGeneralSchema(id) {
    var manifest = pluginManifest(id)
    var settings = manifest && Util.isPlainObject(manifest.settings) ? manifest.settings : null
    return settings && Array.isArray(settings.schema) ? settings.schema : []
  }

  function pluginGeneralDefaults(id) {
    var manifest = pluginManifest(id)
    var settings = manifest && Util.isPlainObject(manifest.settings) ? manifest.settings : null
    return settings && Util.isPlainObject(settings.defaults) ? settings.defaults : ({})
  }

  function pluginSettingsSchema(id) {
    var general = pluginGeneralSchema(id)
    if (general.length > 0) return general
    return widgetSchema(id)
  }

  function pluginSourceDir(id) {
    var manifest = pluginManifest(id)
    return manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  }

  function pluginHasSettings(id) {
    var manifest = pluginManifest(id)
    if (!manifest) return false
    if (pluginGeneralSchema(id).length > 0) return true
    if (pluginIsBarWidget(manifest))
      return widgetHasSettings(id)
    return false
  }

  function pluginVisibleInManager(id, manifest) {
    if (!manifest) return false
    if (manifest.__isFirstParty !== true) return true
    if (pluginIsBarWidget(manifest)) return false
    return true
  }

  function visiblePluginCount() {
    var rev = pluginRevision + catalogRevision
    var count = 0
    var plugins = root.pluginRegistry && root.pluginRegistry.installedPlugins ? root.pluginRegistry.installedPlugins : ({})
    for (var id in plugins) if (pluginVisibleInManager(id, plugins[id])) count++
    return count
  }

  function configurablePluginCount() {
    var rev = pluginRevision + catalogRevision
    var count = 0
    var plugins = root.pluginRegistry && root.pluginRegistry.installedPlugins ? root.pluginRegistry.installedPlugins : ({})
    for (var id in plugins) if (pluginVisibleInManager(id, plugins[id]) && pluginHasSettings(id)) count++
    return count
  }

  function configuredPluginEntry(id) {
    var location = findEntryLocation(id)
    if (location.found) return Util.cloneJson(location.entry)

    var entry = { id: String(id || "") }
    var defaults = pluginGeneralDefaults(id)
    for (var key in defaults) entry[key] = Util.cloneJson(defaults[key])
    return entry
  }

  function managedPlugins() {
    var rev = pluginRevision
    var out = []
    var plugins = root.pluginRegistry && root.pluginRegistry.installedPlugins ? root.pluginRegistry.installedPlugins : ({})
    for (var id in plugins) {
      var manifest = plugins[id]
      if (!pluginVisibleInManager(id, manifest)) continue
      out.push({
        id: id,
        name: manifest.name || id,
        description: manifest.description || "",
        kinds: root.pluginKindText(manifest),
        enabled: root.pluginEnabled(id),
        firstParty: manifest.__isFirstParty === true,
        barWidget: pluginIsBarWidget(manifest),
        configurable: root.pluginHasSettings(id)
      })
    }
    out.sort(function(a, b) {
      if (a.firstParty !== b.firstParty) return a.firstParty ? 1 : -1
      return a.id.localeCompare(b.id)
    })
    return out
  }

  function pluginMatchesFilter(item, filter) {
    if (filter === "Third-party") return !item.firstParty
    if (filter === "Built-in") return item.firstParty && !item.barWidget
    if (filter === "Configurable") return item.firstParty && !item.barWidget && item.configurable
    return true
  }

  function filteredPlugins() {
    var all = managedPlugins()
    var out = []
    for (var i = 0; i < all.length; i++) if (pluginMatchesFilter(all[i], pluginFilter)) out.push(all[i])
    return out
  }

  function pluginFilterCount(filter) {
    var all = managedPlugins()
    var count = 0
    for (var i = 0; i < all.length; i++) if (pluginMatchesFilter(all[i], filter)) count++
    return count
  }

  function rescanPlugins() {
    if (root.pluginRegistry && typeof root.pluginRegistry.rescan === "function")
      root.pluginRegistry.rescan()
  }

  function setPluginEnabled(id, enabled) {
    if (root.pluginRegistry && typeof root.pluginRegistry.setEnabled === "function")
      root.pluginRegistry.setEnabled(id, enabled)
  }

  function installLocalPlugin(path) {
    var src = String(path || "").trim()
    if (!src) {
      localPluginStatus = "Choose a plugin folder first"
      return
    }
    if (installLocalPluginProcess.running) {
      localPluginStatus = "Install already running"
      return
    }
    localPluginStatus = "Installing..."
    pendingEnablePluginId = ""
    var script = ""
      + "set -euo pipefail\n"
      + "src=$1\n"
      + "[[ -d \"$src\" ]] || { echo \"Selected path is not a directory\" >&2; exit 2; }\n"
      + "[[ -f \"$src/manifest.json\" ]] || { echo \"Selected folder does not contain manifest.json\" >&2; exit 3; }\n"
      + "id=$(jq -er '.id | strings' \"$src/manifest.json\")\n"
      + "case \"$id\" in ''|*/*|*..*|/*|omarchy.*) echo \"Invalid or reserved plugin id: $id\" >&2; exit 4;; esac\n"
      + "dest=\"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$id\"\n"
      + "mkdir -p \"$dest\"\n"
      + "cp -a \"$src/.\" \"$dest/\"\n"
      + "printf '%s\\n' \"$id\"\n"
    installLocalPluginProcess.command = ["bash", "-c", script, "local-settings-install-plugin", src]
    installLocalPluginProcess.running = true
  }

  // ---------------- online install helpers ----------------------------------
  function installPluginFromGit(url) {
    var src = String(url || "").trim()
    if (!src) {
      root.onlineInstallStatus = "Enter a git URL"
      return
    }
    root.onlineInstallStatus = "Installing " + src + "..."
    installFromSourceProcess.command = ["bash", "-c", "omarchy plugin add " + Util.shellQuote(src) + " --enable --yes"]
    installFromSourceProcess.running = true
  }

  property Process installLocalPluginProcess: Process {
    stdout: StdioCollector { id: installLocalPluginStdout; waitForEnd: true }
    stderr: StdioCollector { id: installLocalPluginStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(installLocalPluginStdout.text || "").trim()
      var err = String(installLocalPluginStderr.text || "").trim()
      if (exitCode === 0 && out) {
        root.pendingEnablePluginId = out.split("\n")[0]
        root.localPluginStatus = "Installed " + root.pendingEnablePluginId + "; rescanning..."
        root.rescanPlugins()
      } else {
        root.localPluginStatus = err || ("Install failed with exit code " + exitCode)
      }
    }
  }

  // ---------------- online install processes --------------------------------
  property Process installFromSourceProcess: Process {
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code === 0) {
        root.onlineInstallStatus = "Plugin installed"
        root.rescanPlugins()
      } else {
        var err = String(stderr.text || "").trim()
        root.onlineInstallStatus = err || "Failed to install plugin"
      }
    }
  }

  FileView {
    id: userConfigReader
    path: root.userConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.rememberUserConfig(text())
    onFileChanged: reload()
    onLoadFailed: function(error) {
      root.userConfigLoaded = true
      if (!root.draftLoaded) Qt.callLater(root.loadConfig)
    }
  }

  Component.onCompleted: {
    Qt.callLater(loadConfig)
  }

  // ---------------- window -------------------------------------------------
  // ---------------- per-widget settings dialog state -----------------------
  property bool widgetDialogVisible: false
  property string widgetDialogSection: ""
  property int widgetDialogIndex: -1
  property var widgetDialogEntry: ({})
  property bool pluginDialogVisible: false
  property string pluginDialogId: ""
  property var pluginDialogEntry: ({})

  function openWidgetSettings(sectionKey, entryIndex, entry) {
    widgetDialogEntry = Util.cloneJson(entry)
    widgetDialogSection = sectionKey
    widgetDialogIndex = entryIndex
    widgetDialogVisible = true
  }

  function commitWidgetSettings() {
    if (widgetDialogFormLoader.item && typeof widgetDialogFormLoader.item.saveSettings === "function") {
      widgetDialogFormLoader.item.saveSettings()
    } else {
      root.updateEntry(widgetDialogSection, widgetDialogIndex, widgetDialogEntry)
    }
    widgetDialogVisible = false
  }

  function discardWidgetSettings() { widgetDialogVisible = false }

  function widgetDialogFieldChanged(key, value) {
    var copy = Util.cloneJson(widgetDialogEntry)
    copy[key] = value
    widgetDialogEntry = copy
    if (widgetDialogFormLoader.item && "entry" in widgetDialogFormLoader.item)
      widgetDialogFormLoader.item.entry = widgetDialogEntry
  }

  function openPluginSettings(id) {
    if (!pluginHasSettings(id)) return
    pluginDialogId = String(id || "")
    pluginDialogEntry = configuredPluginEntry(pluginDialogId)
    pluginDialogVisible = true
  }

  function pluginName(id) {
    var manifest = pluginManifest(id)
    return manifest ? (manifest.name || id) : id
  }

  function pluginDescription(id) {
    var manifest = pluginManifest(id)
    return manifest ? (manifest.description || "") : ""
  }

  function commitPluginSettings() {
    var entry = Util.cloneJson(pluginDialogEntry)
    if (!entry.id) entry.id = pluginDialogId

    var location = findEntryLocation(pluginDialogId)
    if (location.found) {
      updateEntry(location.section, location.index, entry)
    } else {
      var manifest = pluginManifest(pluginDialogId)
      var isBarWidget = pluginIsBarWidget(manifest)
      mutateSection(isBarWidget ? "right" : "plugins", function(a) { a.push(entry) })
    }
    pluginDialogVisible = false
  }

  function discardPluginSettings() { pluginDialogVisible = false }

  function pluginDialogFieldChanged(key, value) {
    var copy = Util.cloneJson(pluginDialogEntry)
    copy[key] = value
    pluginDialogEntry = copy
    if (pluginDialogFormLoader.item && "entry" in pluginDialogFormLoader.item)
      pluginDialogFormLoader.item.entry = pluginDialogEntry
  }

  FloatingWindow {
    id: window
    title: "Omarchy Settings"
    color: root.background
    implicitWidth: Style.space(760)
    implicitHeight: Style.space(620)
    minimumSize: Qt.size(Style.space(620), Style.space(480))

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide((root.manifest && root.manifest.id) || "shell.settings")
      if (visible) Qt.callLater(root.parkFocusOnSink)
    }

    FocusScope {
      id: navRoot
      anchors.fill: parent
      focus: true

      Component.onCompleted: navFocusSink.forceActiveFocus()

      // Invisible focus sink. When no specific body item is focused,
      // activeFocus lives on this 1px Item so body controls render their
      // unfocused state cleanly.
      Item {
        id: navFocusSink
        width: 1
        height: 1
        objectName: "navFocusSink"
      }

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        switch (event.key) {
        case Qt.Key_Escape:
          root.close(); event.accepted = true; return
        case Qt.Key_J:
        case Qt.Key_Down:
        case Qt.Key_Tab:
          root.focusBodyDelta(+1); event.accepted = true; return
        case Qt.Key_K:
        case Qt.Key_Up:
        case Qt.Key_Backtab:
          root.focusBodyDelta(-1); event.accepted = true; return
        }
      }

      Rectangle {
        anchors.fill: parent
        color: root.background
        // No explicit border — the Hyprland window decoration already draws one.

        ColumnLayout {
          anchors.fill: parent
          spacing: 0

          // Header
          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(Style.space(48), Style.font.heading + Style.spacing.controlPaddingY * 2)

            Text {
              text: "Omarchy Settings"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.panelPadding
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: "~/.config/omarchy/shell.json"
              color: Qt.darker(root.foreground, 1.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.panelPadding
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.spacing.hairline
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
          }

          // Content
          Flickable {
            id: bodyScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: Style.spacing.panelPadding
            clip: true
            contentWidth: width
            contentHeight: contentColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: !folderPicker.visible && !root.widgetDialogVisible && !root.pluginDialogVisible

            ColumnLayout {
              id: contentColumn
              width: bodyScroll.width
              spacing: Style.spacing.panelGap

              PluginCategory { Layout.fillWidth: true }
              IdleCategory { Layout.fillWidth: true }
              BarCategory { Layout.fillWidth: true }
            }
          }
        }
      }
    }

    // ---------- per-widget settings overlay -----------------------------------
    Rectangle {
      anchors.fill: parent
      visible: root.widgetDialogVisible
      color: Qt.rgba(0, 0, 0, 0.45)
      z: 100

      focus: visible
      onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)

      MouseArea {
        anchors.fill: parent
        onClicked: root.discardWidgetSettings()
        acceptedButtons: Qt.LeftButton | Qt.RightButton
      }

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.discardWidgetSettings()
          event.accepted = true
        }
      }

      Rectangle {
        anchors.centerIn: parent
        width: Math.min(Style.space(420), parent.width - Style.gapsOut * 2)
        height: Math.min(parent.height - Style.space(60), Style.space(380))
        color: root.background
        radius: Style.cornerRadius
        border.color: Style.normalBorderFor(root.foreground, root.accent)
        border.width: Style.normalBorderWidth

        MouseArea { anchors.fill: parent }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.spacing.panelPadding
          spacing: Style.spacing.rowPaddingX

          Text {
            text: root.widgetName(root.widgetDialogEntry.id || "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            text: root.widgetDescription(root.widgetDialogEntry.id || "")
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
          }

          Flickable {
            id: widgetDialogScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: widgetDialogFormLoader.item ? widgetDialogFormLoader.item.implicitHeight : 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Loader {
              id: widgetDialogFormLoader
              width: widgetDialogScroll.width
              sourceComponent: root.widgetDialogVisible ? formComponent(root.widgetDialogEntry.id || "") : null
              onLoaded: {
                if (item && "entry" in item) item.entry = root.widgetDialogEntry
                if (item && "fieldChanged" in item) {
                  item.fieldChanged.connect(function(key, value) { root.widgetDialogFieldChanged(key, value) })
                }
              }
            }
          }

          Row {
            Layout.alignment: Qt.AlignRight
            spacing: Style.spacing.rowGap
            Button {
              text: "Cancel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              onClicked: root.discardWidgetSettings()
            }
            Button {
              text: "Apply"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              bordered: true
              onClicked: root.commitWidgetSettings()
            }
          }
        }
      }
    }

    // ---------- per-plugin settings overlay -----------------------------------
    Rectangle {
      anchors.fill: parent
      visible: root.pluginDialogVisible
      color: Qt.rgba(0, 0, 0, 0.45)
      z: 101

      focus: visible
      onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)

      MouseArea {
        anchors.fill: parent
        onClicked: root.discardPluginSettings()
        acceptedButtons: Qt.LeftButton | Qt.RightButton
      }

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.discardPluginSettings()
          event.accepted = true
        }
      }

      Rectangle {
        anchors.centerIn: parent
        width: Math.min(Style.space(460), parent.width - Style.gapsOut * 2)
        height: Math.min(parent.height - Style.space(60), Style.space(420))
        color: root.background
        radius: Style.cornerRadius
        border.color: Style.normalBorderFor(root.foreground, root.accent)
        border.width: Style.normalBorderWidth

        MouseArea { anchors.fill: parent }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.spacing.panelPadding
          spacing: Style.spacing.rowPaddingX

          Text {
            text: root.pluginName(root.pluginDialogId)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            text: root.pluginDescription(root.pluginDialogId)
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
          }

          Flickable {
            id: pluginDialogScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: pluginDialogFormLoader.item ? pluginDialogFormLoader.item.implicitHeight : 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Loader {
              id: pluginDialogFormLoader
              width: pluginDialogScroll.width
              sourceComponent: root.pluginDialogVisible ? pluginFormComponent(root.pluginDialogId) : null
              onLoaded: {
                if (item && "entry" in item) item.entry = root.pluginDialogEntry
                if (item && "fieldChanged" in item) {
                  item.fieldChanged.connect(function(key, value) { root.pluginDialogFieldChanged(key, value) })
                }
              }
            }
          }

          Row {
            Layout.alignment: Qt.AlignRight
            spacing: Style.spacing.rowGap
            Button {
              text: "Cancel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              onClicked: root.discardPluginSettings()
            }
            Button {
              text: "Apply"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              bordered: true
              onClicked: root.commitPluginSettings()
            }
          }
        }
      }
    }

    Cmp.FolderPicker {
      id: folderPicker
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      cornerRadius: root.cornerRadius
      background: root.background
      urgent: root.urgent
      onSelected: function(path) {
        installSection.localPluginPath = path
        installSection.localPluginStatus = ""
      }
      onCancelled: {
        installSection.localPluginStatus = "Folder picker cancelled"
      }
    }
  }

  // ===================== plugin category ==================================
  component PluginCategory: ColumnLayout {
    spacing: Style.spacing.panelGap

    Text {
      text: "Plugins"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge
      font.bold: true
    }

    Text {
      text: "Rescan plugins, enable third-party entries, and edit declared plugin settings. Built-in bar widgets stay in the Bar section."
      color: Qt.darker(root.foreground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      Layout.fillWidth: true
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.rowGap

      Button {
        text: "Rescan plugins"
        foreground: root.foreground
        fontFamily: root.fontFamily
        focusable: true
        bordered: true
        onClicked: root.rescanPlugins()
      }

      Text {
        text: root.visiblePluginCount() + " shown  ·  " + root.configurablePluginCount() + " configurable"
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }

      Item { Layout.fillWidth: true; implicitHeight: 1 }
    }

    ButtonGroup {
      options: [
        "Third-party",
        "Built-in",
        "Configurable"
      ]
      value: root.pluginFilter
      foreground: root.foreground
      background: root.background
      accent: root.accent
      fontFamily: root.fontFamily
      onChanged: function(v) { root.pluginFilter = v }
    }

    Text {
      text: root.pluginFilter === "Third-party"
        ? root.pluginFilterCount("Third-party") + " third-party plugins, including bar widgets and non-bar plugins."
        : (root.pluginFilter === "Built-in"
          ? root.pluginFilterCount("Built-in") + " built-in non-bar Omarchy plugins."
          : root.pluginFilterCount("Configurable") + " built-in non-bar plugins with declared settings.")
      color: Qt.darker(root.foreground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      Layout.fillWidth: true
    }

    Cmp.InstallSection {
      id: installSection
      foreground: root.foreground
      accent: root.accent
      urgent: root.urgent
      fontFamily: root.fontFamily
      cornerRadius: root.cornerRadius
      localPluginStatus: root.localPluginStatus
      onlineInstallStatus: root.onlineInstallStatus
      installLocalBusy: installLocalPluginProcess.running
      installFromSourceBusy: installFromSourceProcess.running

      onInstallLocalRequested: function(path) { root.installLocalPlugin(path) }
      onBrowseRequested: { root.localPluginStatus = ""; folderPicker.open() }
      onInstallFromSourceRequested: function(url) { root.installPluginFromGit(url) }
    }

    Column {
      Layout.fillWidth: true
      spacing: Style.spacing.labelGap

      Repeater {
        model: root.filteredPlugins()
        delegate: Rectangle {
          required property var modelData
          width: parent.width
          implicitHeight: Math.max(Style.space(58), pluginText.implicitHeight + Style.spacing.rowPaddingX * 2)
          radius: root.cornerRadius
          color: pluginMouse.containsMouse
            ? Style.hoverFillFor(root.foreground, root.accent)
            : Style.normalFillFor(root.foreground, root.accent)
          border.color: pluginMouse.containsMouse
            ? Style.hoverBorderFor(root.foreground, root.accent)
            : Style.normalBorderFor(root.foreground, root.accent)
          border.width: pluginMouse.containsMouse ? Style.hoverBorderWidth : Style.normalBorderWidth

          Column {
            id: pluginText
            anchors.left: parent.left
            anchors.right: pluginActions.left
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              text: modelData.name + "  ·  " + modelData.id
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: (modelData.description ? modelData.description + "  ·  " : "")
                + modelData.kinds
                + (modelData.firstParty ? "  ·  built in" : "")
                + (modelData.configurable ? "  ·  settings" : "")
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: pluginActions
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.labelGap

            Button {
              text: "Settings"
              visible: modelData.configurable
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              bordered: true
              onClicked: root.openPluginSettings(modelData.id)
            }

            Button {
              text: modelData.firstParty ? "Built in" : (modelData.enabled ? "Disable" : "Enable")
              enabled: !modelData.firstParty
              foreground: modelData.enabled && !modelData.firstParty ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              focusable: !modelData.firstParty
              bordered: true
              onClicked: root.setPluginEnabled(modelData.id, !modelData.enabled)
            }
          }

          MouseArea {
            id: pluginMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
          }
        }
      }

      Rectangle {
        visible: root.filteredPlugins().length === 0
        width: parent.width
        height: Math.max(Style.space(32), Style.font.bodySmall + Style.spacing.controlPaddingY * 2)
        radius: root.cornerRadius
        color: Style.normalFillFor(root.foreground, root.accent)
        border.color: Style.normalBorderFor(root.foreground, root.accent)
        border.width: Style.normalBorderWidth

        Text {
          anchors.centerIn: parent
          text: "No plugins in this view"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Style.spacing.hairline
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
    }
  }

  component IdleCategory: ColumnLayout {
    spacing: Style.spacing.panelGap

    Text {
      text: "Idle"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge
      font.bold: true
    }

    Text {
      text: "Set when Omarchy starts the screensaver and when it locks after you stop using the system."
      color: Qt.darker(root.foreground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      Layout.fillWidth: true
    }

    Row {
      Layout.fillWidth: true
      spacing: Style.spacing.panelGap

      NumberField {
        label: "Screensaver after (seconds)"
        from: 0
        to: 86400
        stepSize: 5
        value: root.draft.idle && root.draft.idle.screensaver !== undefined ? root.draft.idle.screensaver : 150
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fieldWidth: Style.space(180)
        onModified: function(v) { root.updateIdle("screensaver", v) }
      }

      NumberField {
        label: "Lock after (seconds)"
        from: 0
        to: 86400
        stepSize: 5
        value: root.draft.idle && root.draft.idle.lock !== undefined ? root.draft.idle.lock : 300
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fieldWidth: Style.space(180)
        onModified: function(v) { root.updateIdle("lock", v) }
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Style.spacing.hairline
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
    }
  }

  component BarCategory: ColumnLayout {
    spacing: Style.spacing.panelGap

    Text {
      text: "Bar"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge
      font.bold: true
    }

    Text {
      text: "Drag widgets between the bar's three sections, drop in plugin widgets, and tweak per-widget options. Auto-saves to shell.json."
      color: Qt.darker(root.foreground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      Layout.fillWidth: true
    }

    Row {
      Layout.fillWidth: true
      spacing: Style.spacing.panelGap

      Column {
        spacing: Style.spacing.labelGap

        Text {
          text: "Position"
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        ButtonGroup {
          options: ["top", "right", "bottom", "left"]
          value: root.draft.bar.position
          foreground: root.foreground
          background: root.background
          accent: root.accent
          fontFamily: root.fontFamily
          onChanged: function(v) {
            if (root.draft.bar.position === v) return
            var next = Util.cloneJson(root.draft)
            next.bar.position = v
            root.draft = next
            root.markDirty()
          }
        }
      }

      Cmp.NDropdown {
        label: "Center anchor"
        value: root.draft.bar.centerAnchor || "(none)"
        options: {
          var list = ["(none)"]
          var entries = root.draft.bar.layout.center || []
          for (var i = 0; i < entries.length; i++) list.push(entries[i].id)
          return list
        }
        foreground: root.foreground
        background: root.background
        accent: root.accent
        fontFamily: root.fontFamily
        cornerRadius: root.cornerRadius
        onChanged: function(v) {
          var next = Util.cloneJson(root.draft)
          next.bar.centerAnchor = v === "(none)" ? "" : v
          root.draft = next
          root.markDirty()
        }
      }
    }

    Toggle {
      Layout.fillWidth: true
      label: "Transparent bar"
      description: "Hide the bar background so the wallpaper shows through."
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      checked: root.draft.bar.transparent === true
      onClicked: {
        var next = Util.cloneJson(root.draft)
        next.bar.transparent = !(next.bar.transparent === true)
        root.draft = next
        root.markDirty()
      }
    }

    SectionEditor { sectionKey: "left";    sectionLabel: "Bar · Left" }
    SectionEditor { sectionKey: "center";  sectionLabel: "Bar · Center" }
    SectionEditor { sectionKey: "right";   sectionLabel: "Bar · Right" }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Style.spacing.hairline
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
    }

    Row {
      Layout.alignment: Qt.AlignRight
      Button {
        text: "Reset bar to defaults"
        foreground: root.urgent
        fontFamily: root.fontFamily
        focusable: true
        bordered: true
        onClicked: root.resetBarToDefaults()
      }
    }
  }

  // ===================== bar layout pieces =================================
  component SectionEditor: Column {
    id: section

    property string sectionKey: ""
    property string sectionLabel: ""
    property var entries: root.sectionArray(section.sectionKey)
    Layout.fillWidth: true
    Layout.topMargin: Style.spacing.rowGap
    spacing: Style.spacing.rowGap

    Connections {
      target: root
      function onDraftRevisionChanged() { section.entries = root.sectionArray(section.sectionKey) }
    }

    RowLayout {
      width: section.width
      spacing: Style.spacing.rowGap

      Text {
        text: section.sectionLabel
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        text: "·  " + section.entries.length + (section.entries.length === 1 ? " widget" : " widgets")
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }

      Item { Layout.fillWidth: true; implicitHeight: 1 }

      SearchableDropdown {
        id: addPill
        showLabel: false
        triggerLabel: "󰐕 Add widget"
        value: ""
        placeholderText: "Search widgets..."
        emptyText: "No widgets to add"
        Layout.preferredWidth: Style.spacing.searchableDropdownWidth
        Layout.alignment: Qt.AlignVCenter
        options: {
          var list = root.availableToAdd(section.sectionKey)
          var out = []
          for (var i = 0; i < list.length; i++) {
            out.push({
              value: list[i].id,
              label: list[i].name + (list[i].elsewhere ? "  (elsewhere)" : ""),
              description: list[i].description || ""
            })
          }
          return out
        }
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onChanged: function(v) {
          if (!v) return
          root.addEntry(section.sectionKey, v)
          addPill.value = ""
        }
      }
    }

    Column {
      Layout.fillWidth: true
      width: section.width
      spacing: Style.spacing.labelGap

      Repeater {
        model: section.entries
        delegate: WidgetCard {
          required property var modelData
          required property int index
          width: section.width
          sectionKey: section.sectionKey
          entryIndex: index
          entry: modelData
        }
      }

      Rectangle {
        visible: section.entries.length === 0
        width: parent.width
        height: Math.max(Style.space(32), Style.font.bodySmall + Style.spacing.controlPaddingY * 2)
        radius: root.cornerRadius
        color: Style.normalFillFor(root.foreground, root.accent)
        border.color: Style.normalBorderFor(root.foreground, root.accent)
        border.width: Style.normalBorderWidth

        Text {
          anchors.centerIn: parent
          text: "Empty — add a widget"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  component WidgetCard: Rectangle {
    id: card
    property string sectionKey: ""
    property int entryIndex: -1
    property var entry: ({})
    readonly property string entryId: entry && entry.id ? String(entry.id) : ""
    readonly property string displayName: root.widgetName(entryId)
    readonly property string description: root.widgetDescription(entryId)
    readonly property bool hasSettings: root.widgetHasSettings(entryId)

    implicitHeight: Style.space(50)
    radius: root.cornerRadius
    color: cardArea.containsMouse || actionRow.activeFocus
      ? Style.hoverFillFor(root.foreground, root.accent)
      : Style.normalFillFor(root.foreground, root.accent)
    border.color: cardArea.containsMouse || actionRow.activeFocus
      ? Style.hoverBorderFor(root.foreground, root.accent)
      : Style.normalBorderFor(root.foreground, root.accent)
    border.width: cardArea.containsMouse || actionRow.activeFocus ? Style.hoverBorderWidth : Style.normalBorderWidth

    Behavior on color { ColorAnimation { duration: 100 } }

    function maybeRestoreActionFocus() {
      if (root.pendingActionFocusSection !== card.sectionKey) return
      if (root.pendingActionFocusIndex !== card.entryIndex) return

      actionRow.actionIndex = root.pendingActionFocusAction
      actionRow.clampActionIndex()
      root.clearPendingActionFocus()

      Qt.callLater(function() {
        actionRow.forceActiveFocus()
        root.ensureBodyItemVisible(card)
      })
    }

    onEntryIndexChanged: maybeRestoreActionFocus()
    Component.onCompleted: maybeRestoreActionFocus()

    Connections {
      target: root
      function onPendingActionFocusRevisionChanged() { card.maybeRestoreActionFocus() }
    }

    Row {
      id: actionRow
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlGap
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.labelGap
      activeFocusOnTab: true

      property int actionIndex: 0

      onActiveFocusChanged: if (activeFocus) {
        clampActionIndex()
        root.ensureBodyItemVisible(card)
      }

      function actionVisible(index) {
        switch (index) {
        case 0: return moveUpButton.visible && moveUpButton.enabled
        case 1: return moveDownButton.visible && moveDownButton.enabled
        case 2: return settingsButton.visible && settingsButton.enabled
        case 3: return removeButton.visible && removeButton.enabled
        }
        return false
      }

      function firstActionIndex() {
        for (var i = 0; i < 4; i++) if (actionVisible(i)) return i
        return 0
      }

      function clampActionIndex() {
        if (actionVisible(actionIndex)) return
        actionIndex = firstActionIndex()
      }

      function moveAction(delta) {
        clampActionIndex()
        var next = actionIndex
        while (true) {
          next += delta
          if (next < 0 || next > 3) return
          if (actionVisible(next)) { actionIndex = next; return }
        }
      }

      function activateAction() {
        clampActionIndex()
        switch (actionIndex) {
        case 0: root.moveEntry(card.sectionKey, card.entryIndex, card.entryIndex - 1, actionIndex); return
        case 1: root.moveEntry(card.sectionKey, card.entryIndex, card.entryIndex + 1, actionIndex); return
        case 2: root.openWidgetSettings(card.sectionKey, card.entryIndex, card.entry); return
        case 3: root.removeEntry(card.sectionKey, card.entryIndex); return
        }
      }

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Left || event.text === "h") {
          moveAction(-1); event.accepted = true; return
        }
        if (event.key === Qt.Key_Right || event.text === "l") {
          moveAction(1); event.accepted = true; return
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          activateAction(); event.accepted = true; return
        }
      }

      PanelActionButton {
        id: moveUpButton
        iconText: "󰁝"
        tooltipText: "Move up"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.subtitle
        size: Style.space(26)
        hasCursor: actionRow.activeFocus && actionRow.actionIndex === 0
        bordered: hasCursor
        onHovered: function(h) { if (h) actionRow.actionIndex = 0 }
        onClicked: root.moveEntry(card.sectionKey, card.entryIndex, card.entryIndex - 1, 0)
      }
      PanelActionButton {
        id: moveDownButton
        iconText: "󰁅"
        tooltipText: "Move down"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.subtitle
        size: Style.space(26)
        hasCursor: actionRow.activeFocus && actionRow.actionIndex === 1
        bordered: hasCursor
        onHovered: function(h) { if (h) actionRow.actionIndex = 1 }
        onClicked: root.moveEntry(card.sectionKey, card.entryIndex, card.entryIndex + 1, 1)
      }
      PanelActionButton {
        id: settingsButton
        iconText: "󰒓"
        tooltipText: "Settings"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.subtitle
        size: Style.space(26)
        visible: card.hasSettings
        hasCursor: actionRow.activeFocus && actionRow.actionIndex === 2
        bordered: hasCursor
        onVisibleChanged: if (!visible && actionRow.actionIndex === 2) actionRow.clampActionIndex()
        onHovered: function(h) { if (h) actionRow.actionIndex = 2 }
        onClicked: root.openWidgetSettings(card.sectionKey, card.entryIndex, card.entry)
      }
      PanelActionButton {
        id: removeButton
        iconText: "󰅖"
        tooltipText: "Remove"
        foreground: root.urgent
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        fontSize: Style.font.subtitle
        size: Style.space(26)
        hasCursor: actionRow.activeFocus && actionRow.actionIndex === 3
        bordered: hasCursor
        onHovered: function(h) { if (h) actionRow.actionIndex = 3 }
        onClicked: root.removeEntry(card.sectionKey, card.entryIndex)
      }
    }

    Column {
      anchors.left: parent.left
      anchors.right: actionRow.left
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs

      Text {
        text: card.displayName
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }
      Text {
        visible: text !== ""
        text: card.description
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
      }
    }

    MouseArea {
      id: cardArea
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }
  }

  // ---------------- per-widget form resolution -----------------------------
  function formComponent(id) {
    var meta = widgetMetadata(id)
    if (meta && meta.settingsForm) {
      switch (meta.settingsForm) {
      case "spacerSettings": return spacerSettingsComponent
      case "clockSettings": return clockSettingsComponent
      case "weatherSettings": return weatherSettingsComponent
      }
    }
    if (widgetSchema(id).length > 0) return dynamicSettingsComponent
    return null
  }

  function pluginFormComponent(id) {
    if (pluginGeneralSchema(id).length > 0) return pluginDynamicSettingsComponent
    return formComponent(id)
  }

  Component {
    id: dynamicSettingsComponent
    Cmp.DynamicSettingsForm {
      schema: root.widgetSchema(entry.id || "")
      pluginSourceDir: root.widgetSourceDir(entry.id || "")
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }

  Component {
    id: pluginDynamicSettingsComponent
    Cmp.DynamicSettingsForm {
      schema: root.pluginSettingsSchema(entry.id || root.pluginDialogId)
      pluginSourceDir: root.pluginSourceDir(entry.id || root.pluginDialogId)
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }

  Component {
    id: spacerSettingsComponent

    Column {
      id: spacerForm
      signal fieldChanged(string key, var value)
      property var entry: ({})

      spacing: Style.spacing.rowGap
      width: parent ? parent.width : 0

      NumberField {
        label: "Size (pixels)"
        from: 0
        to: 256
        value: spacerForm.entry.size !== undefined ? spacerForm.entry.size : 12
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onModified: function(v) { spacerForm.fieldChanged("size", v) }
      }
    }
  }

  Component {
    id: clockSettingsComponent

    Column {
      id: clockForm
      signal fieldChanged(string key, var value)
      property var entry: ({})

      spacing: Style.spacing.rowGap
      width: parent ? parent.width : 0

      component ClockField: TextField {
        property string fieldKey: ""
        width: parent.width
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        onEditingFinished: if (fieldKey) clockForm.fieldChanged(fieldKey, text)
      }

      Text {
        text: "Horizontal format"
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      ClockField {
        fieldKey: "format"
        text: clockForm.entry.format || "dddd HH:mm"
      }

      Text {
        text: "Alternate format (click to toggle)"
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      ClockField {
        fieldKey: "formatAlt"
        text: clockForm.entry.formatAlt || "dd MMMM 'W'ww yyyy"
      }

      Text {
        text: "Vertical format (left/right bars)"
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      ClockField {
        fieldKey: "verticalFormat"
        text: clockForm.entry.verticalFormat || "HH\n—\nmm"
      }
    }
  }

  Component {
    id: weatherSettingsComponent

    Column {
      id: weatherForm
      signal fieldChanged(string key, var value)
      property var entry: ({})

      spacing: Style.spacing.rowGap
      width: parent ? parent.width : 0

      NumberField {
        label: "Auto-refresh interval (minutes)"
        from: 1
        to: 1440
        value: weatherForm.entry.refreshMinutes !== undefined ? weatherForm.entry.refreshMinutes : 15
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onModified: function(v) { weatherForm.fieldChanged("refreshMinutes", v) }
      }
    }
  }


}
