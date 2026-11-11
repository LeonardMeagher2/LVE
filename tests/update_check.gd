extends "res://tests/test.gd"

## Checks the release version logic, the release payload parser, and the status
## bar link. No case uses the network.

const CHECKER := preload("res://ui/StatusBar/UpdateChecker.gd")
const STATUS_SCENE := preload("res://ui/StatusBar/status_bar.tscn")
const RELEASE_URL := "https://github.com/LeonardMeagher2/LVE/releases/tag/v0.3"

var status: EditorStatusBar


func _ready() -> void:
	test("the version comparison uses numeric parts", _compare)
	test("a release outranks its pre-release", _suffix)
	test("the release parser accepts only published release pages", _parse)
	test("the status bar links to the latest release", _status)


func after_test() -> void:
	if is_instance_valid(status):
		status.queue_free()
		status = null


func _compare() -> void:
	step("Given version strings with different numeric parts", func():
		pass
	)
	step("Then the larger number is newer", func():
		expect(CHECKER.is_newer("v0.10", "0.9"), "ten is newer than nine")
		expect(CHECKER.is_newer("v0.2.1", "0.2"), "a patch release is newer")
		expect(not CHECKER.is_newer("v0.2", "0.2.0"), "a missing part counts as zero")
		expect(not CHECKER.is_newer("v0.2", "0.3"), "an older release is not newer")
		expect(not CHECKER.is_newer("nonsense", "0.2"), "an invalid tag is not newer")
	)


func _suffix() -> void:
	step("Given a release and its pre-release", func():
		pass
	)
	step("Then the plain release is newer", func():
		expect(CHECKER.is_newer("v0.3", "0.3-beta"), "a release outranks its pre-release")
		expect(not CHECKER.is_newer("v0.3-beta", "0.3"), "a pre-release is older than the release")
		expect(not CHECKER.is_newer("v0.3-alpha", "0.3-beta"), "two suffixes are not ordered")
	)


func _parse() -> void:
	step("Given valid and invalid GitHub release payloads", func():
		pass
	)
	step("Then only a published release page is accepted", func():
		var valid := {"tag_name": "v0.3", "html_url": RELEASE_URL}
		var release := CHECKER.parse_release(valid)
		expect(release.get("version") == "v0.3", "the tag is kept")
		expect(release.get("url") == RELEASE_URL, "the release page is kept")
		expect(CHECKER.parse_release({"tag_name": "v0.3", "html_url": RELEASE_URL, "draft": true}).is_empty(), "a draft is rejected")
		expect(CHECKER.parse_release({"tag_name": "v0.3", "html_url": RELEASE_URL, "prerelease": true}).is_empty(), "a prerelease is rejected")
		expect(CHECKER.parse_release({"tag_name": "nightly", "html_url": RELEASE_URL}).is_empty(), "an invalid tag is rejected")
		expect(CHECKER.parse_release({"tag_name": "v0.3", "html_url": "https://example.com/release"}).is_empty(), "a foreign page is rejected")
		expect(CHECKER.parse_release({"html_url": RELEASE_URL}).is_empty(), "a missing tag is rejected")
	)


func _status() -> void:
	step("Given the status bar", func():
		status = STATUS_SCENE.instantiate()
		main.add_child(status)
	)
	await get_tree().process_frame
	step("Then the version link opens the releases page before a check", func():
		var link: LinkButton = status.get_node("Version")
		var current := str(ProjectSettings.get_setting("application/config/version", ""))
		expect(link.visible, "the version link is visible")
		expect(link.text == "v" + current, "the link shows the current version")
		expect(link.uri == EditorStatusBar.RELEASES_URL, "the link opens the releases page")
	)
	step("When a newer release arrives", func():
		status.show_latest("v999.0", "https://github.com/LeonardMeagher2/LVE/releases/tag/v999.0", true)
	)
	step("Then the link shows and opens the newer release", func():
		var link: LinkButton = status.get_node("Version")
		expect(link.text.ends_with("v999.0"), "the link shows the newer release")
		expect(link.text.begins_with("v"), "the link keeps the current version")
		expect(link.uri == "https://github.com/LeonardMeagher2/LVE/releases/tag/v999.0", "the link opens the newer release")
		expect(link.tooltip_text == "Open the v999.0 release", "the tooltip names the release")
	)
	step("When the current release arrives", func():
		var current := "v" + str(ProjectSettings.get_setting("application/config/version", ""))
		status.show_latest(current, "https://github.com/LeonardMeagher2/LVE/releases/tag/" + current, false)
	)
	step("Then the link keeps the current version text", func():
		var link: LinkButton = status.get_node("Version")
		var current := "v" + str(ProjectSettings.get_setting("application/config/version", ""))
		expect(link.text == current, "the link shows only the current version")
		expect(link.uri == "https://github.com/LeonardMeagher2/LVE/releases/tag/" + current, "the link opens the current release")
	)
