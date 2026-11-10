extends Node

## Checks GitHub for the latest release when the app starts.
##
## The check runs only in release builds, or when `LVE_UPDATE_CHECK=1` is set.
## Tests and the editor stay offline. The status bar keeps its fallback release
## page until the request returns.

## Emitted with the latest release tag, its page URL, and whether it is newer.
signal latest_release(version: String, url: String, newer: bool)

## The GitHub API endpoint for the latest published release.
const ENDPOINT := "https://api.github.com/repos/LeonardMeagher2/LVE/releases/latest"
## The prefix that every release page URL must use.
const RELEASES_PREFIX := "https://github.com/LeonardMeagher2/LVE/releases/"
## The request timeout in seconds.
const REQUEST_TIMEOUT := 10.0

@onready var _request: HTTPRequest = $HTTPRequest

var _current_version := ""
var _started := false


func _ready() -> void:
	_request.timeout = REQUEST_TIMEOUT
	_request.use_threads = true
	_request.request_completed.connect(_on_request_completed)
	_current_version = str(ProjectSettings.get_setting("application/config/version", ""))


## Starts one check. The status bar calls this after it connects the signal.
func start() -> void:
	if _started:
		return
	_started = true
	if not _enabled() or _current_version.is_empty():
		return
	var headers := PackedStringArray([
		"User-Agent: LVE/%s" % _current_version,
		"Accept: application/vnd.github+json",
		"X-GitHub-Api-Version: 2022-11-28",
	])
	_request.request(ENDPOINT, headers)


func _enabled() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	if OS.has_feature("debug") and OS.get_environment("LVE_UPDATE_CHECK") != "1":
		return false
	return true


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not parsed is Dictionary:
		return
	var release := parse_release(parsed)
	if release.is_empty():
		return
	var version: String = release["version"]
	var url: String = release["url"]
	_emit(version, url)


func _emit(version: String, url: String) -> void:
	latest_release.emit(version, url, is_newer(version, _current_version))


## Returns the release fields for a valid GitHub release payload, or an empty
## dictionary. The payload must be a published release with a release page URL.
static func parse_release(data: Dictionary) -> Dictionary:
	if data.get("draft", false) == true or data.get("prerelease", false) == true:
		return {}
	var tag: Variant = data.get("tag_name")
	if not tag is String:
		return {}
	var version := String(tag)
	if _parse_version(version).is_empty():
		return {}
	var page: Variant = data.get("html_url")
	if not page is String:
		return {}
	var url := String(page)
	if not url.begins_with(RELEASES_PREFIX):
		return {}
	return {"version": version, "url": url}


## Returns true when [param latest] is a newer release than [param current].
## Missing number parts count as zero. A release outranks the same version with
## a suffix. Two suffixes are not ordered.
static func is_newer(latest: String, current: String) -> bool:
	var latest_parts := _parse_version(latest)
	var current_parts := _parse_version(current)
	if latest_parts.is_empty() or current_parts.is_empty():
		return false
	var latest_numbers: Array = latest_parts["numbers"]
	var current_numbers: Array = current_parts["numbers"]
	for index in 3:
		var left: int = latest_numbers[index]
		var right: int = current_numbers[index]
		if left != right:
			return left > right
	var latest_suffix: String = latest_parts["suffix"]
	var current_suffix: String = current_parts["suffix"]
	return latest_suffix.is_empty() and not current_suffix.is_empty()


# Parses a version into three numbers and a suffix. Returns an empty dictionary
# when the text is not a version.
static func _parse_version(text: String) -> Dictionary:
	var value := text.strip_edges()
	if value.begins_with("v") or value.begins_with("V"):
		value = value.substr(1)
	var plus := value.find("+")
	if plus >= 0:
		if plus == value.length() - 1:
			return {}
		value = value.left(plus)
	var suffix := ""
	var dash := value.find("-")
	if dash >= 0:
		suffix = value.substr(dash + 1)
		if suffix.is_empty():
			return {}
		value = value.left(dash)
	if value.is_empty():
		return {}
	var parts := value.split(".")
	if parts.size() > 3:
		return {}
	var numbers: Array[int] = [0, 0, 0]
	for index in parts.size():
		var part := String(parts[index])
		if part.is_empty() or not part.is_valid_int():
			return {}
		var number := part.to_int()
		if number < 0:
			return {}
		numbers[index] = number
	return {"numbers": numbers, "suffix": suffix}
