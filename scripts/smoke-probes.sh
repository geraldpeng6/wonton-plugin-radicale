# shellcheck shell=bash
# Radicale：网页（/.web/）经网关代登录（sso: proxy，X-Remote-User 头）；CalDAV/CardDAV 客户端走 dav
# 服务的 htpasswd Basic（冒烟里不开局域网开关，客户端路径在手动栈实测，结果记进 PR）。
# 清单没有 mcp。

web_assert() { grep -q 'Radicale Web Interface'; }   # /.web/ 内置管理页的 <title>

# 网关注入的身份生效：PROPFIND / 的 current-user-principal 指向主人；不带身份的直接请求被拒。
identity_check() {
  local prop resp code
  if [[ -n "${SMOKE_WEB_ORIGIN:-}" ]]; then
    # curl_t 对 4xx 以 22 退出，但 -w 已把状态码打到标准输出，不能因退出码覆盖它。
    code="$(curl_t "$SMOKE_WEB_MAX_TIME" "$SMOKE_WEB_ORIGIN/" --noproxy '*' -o /dev/null \
      -w '%{http_code}' -X PROPFIND -H 'Depth: 0' 2>/dev/null || true)"
    [[ "$code" == 401 ]] || { echo "匿名 PROPFIND 返回 ${code:-（无响应）}，不是 401"; return 1; }
  fi
  prop='<?xml version="1.0" encoding="utf-8"?><propfind xmlns="DAV:"><prop><current-user-principal/></prop></propfind>'
  resp="$(dweb "/" -X PROPFIND -H "Depth: 0" -H "Content-Type: application/xml" --data "$prop")" ||
    { echo "PROPFIND 失败：$resp"; return 1; }
  grep -q 'current-user-principal' <<<"$resp" ||
    { echo "响应里没有 current-user-principal：$(head -c 300 <<<"$resp")"; return 1; }
  grep -qF "/$SMOKE_OWNER/" <<<"$resp" ||
    { echo "current-user-principal 不是用户 $SMOKE_OWNER：$(head -c 300 <<<"$resp")"; return 1; }
}

# 数据：合并前验证“升级/重装不丢用户数据”：经网关建一个日历、写一个带随机标记的事件，
# 标记存进 $SMOKE_STATE。dweb 是插件 origin 根下的路径，curl 参数原样透传。
dweb_code() { # <路径> <curl 参数…>：只回 HTTP 状态码
  dweb "$@" -o /dev/null -w '%{http_code}'
}

marker_file() { # SMOKE_STATE 在套件里是状态目录（e2e 传的是标记文件本身），标记放对应路径
  if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/radicale-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

data_write() {
  local marker code ics
  marker="wonton-smoke-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  code="$(dweb_code "/$SMOKE_OWNER/wonton-smoke/" -X MKCALENDAR -H 'Depth: 0' -H 'Content-Type: application/xml' \
    --data '<?xml version="1.0" encoding="utf-8"?><mkcalendar xmlns="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><set><prop><resourcetype><collection/><c:calendar/></resourcetype><displayname>wonton smoke</displayname></prop></set></mkcalendar>')" ||
    { echo "MKCALENDAR 请求失败：$code"; return 1; }
  [[ "$code" == 201 ]] || { echo "MKCALENDAR 返回 $code（要 201）"; return 1; }
  ics=$'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//wonton smoke//CN\r\nBEGIN:VEVENT\r\nUID:'"$marker"$'@wonton\r\nDTSTAMP:20261112T000000Z\r\nDTSTART:20261113T090000Z\r\nDTEND:20261113T100000Z\r\nSUMMARY:wonton smoke\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n'
  code="$(dweb_code "/$SMOKE_OWNER/wonton-smoke/$marker.ics" -X PUT -H 'Content-Type: text/calendar' --data-binary "$ics")" ||
    { echo "PUT 请求失败：$code"; return 1; }
  [[ "$code" == 201 ]] || { echo "PUT 事件返回 $code（要 201）"; return 1; }
  printf '%s' "$marker" >"$(marker_file)"
}

data_check() { # 事件还在，标记对得上
  local marker got
  marker="$(cat "$(marker_file)")"
  [[ -n "$marker" ]] || { echo "SMOKE_STATE 里没有标记"; return 1; }
  got="$(dweb "/$SMOKE_OWNER/wonton-smoke/$marker.ics")" || { echo "读回事件失败：$got"; return 1; }
  grep -qF "UID:$marker@wonton" <<<"$got" ||
    { echo "事件对不上：$(head -c 300 <<<"$got")"; return 1; }
}
