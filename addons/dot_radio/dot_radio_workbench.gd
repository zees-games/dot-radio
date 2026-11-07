class_name DotRadioWorkbench
extends RefCounted

## Puts the radio admin page in a dot-workbench. Duck-typed: dot-radio does not depend on dot-workbench, so [param workbench] is anything with a `server` ([DotHttpServer]) and `register_page(id, title, html, flag)` (a `DotWorkbenchHttp`).
##
## The radio routes are mounted on the workbench's own server under [param prefix] (so the page is same-origin and the workbench's CSP `connect-src 'self'` holds), and the page is registered as `/pages/radio`, listed on the workbench index for tokens holding [constant FLAG]. The radio keeps its own token or identity (`DotRadioApi.identity`, which `DotAdminIdentity` fits); the workbench token does not open it.

const ID := "radio"
const TITLE := "Radio"
## The workbench permission that lists the page; the radio API checks its own `radio` flag separately.
const FLAG := "radio"


## Returns false when the workbench refused the page or the prefix is not a plain path. Call once, before the workbench starts; the host still calls `workbench.poll()` and `radio.api.update()` (not `radio.poll()`, which would poll the shared server twice).
static func register(workbench: Object, radio: DotRadioHttp, prefix: String = "/radio", flag: String = FLAG) -> bool:
	var html := page_html(radio, prefix)
	if html.is_empty():
		return false
	radio.mount(workbench.get("server") as DotHttpServer, prefix)
	return bool(workbench.call("register_page", ID, TITLE, html, flag))


## The radio page with its routes' root injected, or "" when the page file is missing or [param prefix] is not like "/radio".
static func page_html(radio: DotRadioHttp, prefix: String = "/radio") -> String:
	if RegEx.create_from_string("^/[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$").search(prefix) == null:
		return ""
	var html := FileAccess.get_file_as_string(radio.page_path) if FileAccess.file_exists(radio.page_path) else ""
	var at := html.find("<head>")
	if at < 0:
		return ""
	return html.insert(at + 6, '<meta name="radio-root" content="%s/">' % prefix)
