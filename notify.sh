#!/usr/bin/env bash
# notify.sh <title> <body>
# PUSH_KEY (repo secret) chooses the channel: "<service>:<key-or-url>"
#   pushdeer:PUSHKEY            https://pushdeer.com        (iOS/Android app)
#   serverchan:SENDKEY          https://sct.ftqq.com         (WeChat, free tier 5 msgs/day)
#   bark:KEY                    https://bark.day.app         (iOS)
#   wecom:WEBHOOK_URL           WeCom group bot webhook
#   dingtalk:WEBHOOK_URL        DingTalk group bot webhook
#   url:GET_URL                 receives ?title=&body=
set -uo pipefail

title="${1:?title}"; body="${2:?body}"
key="${PUSH_KEY:?secret PUSH_KEY is not set}"
svc="${key%%:*}"; val="${key#*:}"
json() { jq -n --arg t "$title" --arg b "$body" "$1"; }

case "$svc" in
  pushdeer)   curl -fsS -m 20 -X POST https://api2.pushdeer.com/message/push \
                --data-urlencode "pushkey=$val" --data-urlencode "text=$title"$'\n'"$body" ;;
  serverchan) curl -fsS -m 20 -X POST "https://sctapi.ftqq.com/$val.send" \
                --data-urlencode "title=$title" --data-urlencode "desp=$body" ;;
  bark)       json '{title:$t, body:$b, group:"pia"}' \
                | curl -fsS -m 20 -X POST "https://api.day.app/$val" -H 'Content-Type: application/json' -d @- ;;
  wecom|dingtalk)
              json '{msgtype:"text", text:{content:($t + "\n" + $b)}}' \
                | curl -fsS -m 20 -X POST "$val" -H 'Content-Type: application/json' -d @- ;;
  url)        curl -fsS -m 20 -G "$val" --data-urlencode "title=$title" --data-urlencode "body=$body" ;;
  *) echo "unknown push service '$svc' (pushdeer|serverchan|bark|wecom|dingtalk|url)" >&2; exit 2 ;;
esac || { echo "push via $svc failed" >&2; exit 1; }
echo "pushed via $svc"
