# Configuration reader for vine.toml.

import std/[os, strutils, tables]

type
  VineConfig* = object
    primaryBranch*: string
    venvPolicy*: string
    vendorDirs*: seq[string]
    testCommand*: string
    activeConfigFile*: string

  BraidConfig* = VineConfig

proc unquote*(s: string): string =
  let t = s.strip()
  if (t.startsWith("\"") and t.endsWith("\"")) or (t.startsWith("'") and t.endsWith("'")):
    if t.len >= 2:
      return t[1 .. ^2]
  return t

proc parseStringList*(val: string): seq[string] =
  var s = val.strip()
  if s.startsWith("[") and s.endsWith("]"):
    s = s[1..^2].strip()
  if s.len == 0: return @[]
  for item in s.split(','):
    let clean = item.strip().unquote()
    if clean.len > 0:
      result.add(clean)

proc parseSimpleToml*(content: string): Table[string, Table[string, string]] =
  result = initTable[string, Table[string, string]]()
  result[""] = initTable[string, string]()
  var curSection = ""

  for rawLine in content.splitLines():
    var line = rawLine.strip()
    if line.len == 0 or line.startsWith("#") or line.startsWith(";"):
      continue

    var inQuotes = false
    var cleanLine = ""
    for c in line:
      if c == '"' or c == '\'': inQuotes = not inQuotes
      elif c == '#' and not inQuotes: break
      cleanLine.add(c)
    cleanLine = cleanLine.strip()
    if cleanLine.len == 0: continue

    if cleanLine.startsWith("[") and cleanLine.endsWith("]"):
      curSection = cleanLine[1 .. ^2].strip().toLowerAscii
      if not result.hasKey(curSection):
        result[curSection] = initTable[string, string]()
      continue

    let eqIdx = cleanLine.find('=')
    if eqIdx > 0:
      let key = cleanLine[0 ..< eqIdx].strip().toLowerAscii
      let val = cleanLine[eqIdx + 1 .. ^1].strip().unquote()
      if not result.hasKey(curSection):
        result[curSection] = initTable[string, string]()
      result[curSection][key] = val

proc findVineConfigPath*(startDir: string = getCurrentDir()): string =
  var cur = startDir
  while true:
    for candidate in ["vine.toml", ".vine.toml"]:
      let p = cur / candidate
      if fileExists(p):
        return p
    if dirExists(cur / ".git") or fileExists(cur / ".git"):
      break
    let parent = cur.parentDir()
    if parent == cur or parent.len == 0:
      break
    cur = parent
  return ""

proc findBraidConfigPath*(startDir: string = getCurrentDir()): string =
  findVineConfigPath(startDir)

proc getWorkspacesBaseDir*(): string =
  let envDir = getEnv("VINE_WORKSPACES_DIR", getEnv("VINE_WORKSPACES", ""))
  if envDir.len > 0:
    return envDir.normalizedPath
  return getHomeDir() / "Development" / "workspaces"

proc getProjectsBaseDir*(): string =
  let envDir = getEnv("VINE_PROJECTS_DIR", getEnv("VINE_DEV_DIR", ""))
  if envDir.len > 0:
    return envDir.normalizedPath
  return getHomeDir() / "Development"

proc loadVineConfig*(configPath: string = ""): VineConfig =
  result = VineConfig(
    primaryBranch: "main",
    venvPolicy: "prompt",
    vendorDirs: @["deps", "nimbledeps", "vendor", "node_modules", ".zig-cache"],
    testCommand: "",
    activeConfigFile: ""
  )

  let envConfig = getEnv("VINE_CONFIG", "")
  let path = if configPath.len > 0: configPath
             elif envConfig.len > 0 and fileExists(envConfig): envConfig
             else: findVineConfigPath()
  if path.len > 0 and fileExists(path):
    result.activeConfigFile = path
    let toml = parseSimpleToml(readFile(path))

    for secName, dict in toml:
      for k, v in dict:
        let low = k.toLowerAscii.replace("-", "_")
        case low
        of "primary_branch", "primarybranch", "main_branch", "default_branch":
          if v.len > 0: result.primaryBranch = v
        of "venv_policy", "venvpolicy":
          if v.len > 0: result.venvPolicy = v.toLowerAscii
        of "vendor_dirs", "vendordirs":
          if v.len > 0: result.vendorDirs = parseStringList(v)
        of "test_command", "testcommand", "build_command":
          if v.len > 0: result.testCommand = v
        else:
          discard

  # Environment variable overrides (highest precedence)
  let envPrimary = getEnv("VINE_PRIMARY_BRANCH", "")
  if envPrimary.len > 0: result.primaryBranch = envPrimary

  let envTest = getEnv("VINE_TEST_COMMAND", "")
  if envTest.len > 0: result.testCommand = envTest

  let envVenv = getEnv("VINE_VENV_POLICY", "")
  if envVenv.len > 0: result.venvPolicy = envVenv.toLowerAscii

proc loadBraidConfig*(configPath: string = ""): BraidConfig =
  loadVineConfig(configPath)
