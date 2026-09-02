# QuotaHarbor localization glossary

This glossary fixes product meaning across all supported locales: Follow
System plus zh-Hant, zh-Hans, en, ja, ko, es, fr, and de. The current
product boundary keeps Codex enabled and lets the user optionally display Claude Code. Google Antigravity
and Kimi Code terms remain only for dormant compatibility/test strings. Codex
activity rows are UTC observations, not billing records.

| Canonical term | zh-Hant | zh-Hans | en | ja | ko | es | fr | de |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| quota window | 額度窗口 | 额度窗口 | quota window | 使用量ウインドウ | 할당량 기간 | ventana de cuota | fenêtre de quota | Kontingentfenster |
| used | 已使用 | 已使用 | used | 使用済み | 사용됨 | usado | utilisé | verbraucht |
| remaining | 剩餘 | 剩余 | remaining | 残り | 남음 | restante | restant | verbleibend |
| reset | 重設 | 重置 | reset | リセット | 재설정 | restablecimiento | réinitialisation | Zurücksetzen |
| stale | 已過期 | 已过期 | stale | 期限切れ | 오래됨 | desactualizado | périmé | veraltet |
| unsupported | 不支援 | 不支持 | unsupported | 未対応 | 지원되지 않음 | no compatible | non pris en charge | nicht unterstützt |
| token activity | Token 活動 | Token 活动 | token activity | トークンアクティビティ | 토큰 활동 | actividad de tokens | activité des jetons | Token-Aktivität |
| derived | 推算 | 推算 | derived | 算出 | 계산됨 | derivado | dérivé | abgeleitet |
| partial | 部分 | 部分 | partial | 一部 | 일부 | parcial | partiel | teilweise |
| not returned | 未回傳 | 未返回 | not returned | 返されていません | 반환되지 않음 | no devuelto | non renvoyé | nicht zurückgegeben |
| provider | 來源 | 提供方 | provider | プロバイダー | 제공자 | proveedor | fournisseur | Anbieter |
| connected | 已連線 | 已连接 | connected | 接続済み | 연결됨 | conectado | connecté | verbunden |
| not connected | 未連線 | 未连接 | not connected | 未接続 | 연결되지 않음 | no conectado | non connecté | nicht verbunden |
| installed | 已安裝 | 已安装 | installed | インストール済み | 설치됨 | instalado | installé | installiert |
| running | 執行中 | 正在运行 | running | 実行中 | 실행 중 | en ejecución | en cours d’exécution | wird ausgeführt |
| command available | 指令可用 | 命令可用 | command available | コマンド利用可能 | 명령 사용 가능 | comando disponible | commande disponible | Befehl verfügbar |
| last updated | 上次更新 | 上次更新 | last updated | 最終更新 | 마지막 업데이트 | última actualización | dernière mise à jour | zuletzt aktualisiert |
| status-line relay | 狀態列 relay | 状态栏中继 | status-line relay | ステータスラインリレー | 상태 표시줄 릴레이 | relé de línea de estado | relais de ligne d’état | Statuszeilen-Relay |
| manual recovery | 手動復原 | 手动恢复 | manual recovery | 手動復旧 | 수동 복구 | recuperación manual | récupération manuelle | manuelle Wiederherstellung |

## Meaning rules

- `quota window` is a backend limit interval; do not translate it as a billing
  cycle unless the backend explicitly says so.
- `used` and `remaining` describe a reported quota percentage, never money.
- `reset` is the backend-provided reset time, not an account renewal date.
- `stale` means the last valid value is being shown past freshness policy.
- `unsupported` means a capability is not exposed; it does not mean the user
  has zero quota.
- `installed`, `running`, and `command available` describe local component
  presence only; they are not proof of provider login or quota availability.
  Never translate them as logged in, connected to a subscription, or quota
  available.
- `connected` for Claude Code means the bounded local `auth status` check
  succeeded; it is not a billing, subscription, or quota guarantee.
- Keep official provider names unchanged: Google Antigravity, Codex, Claude
  Code, and Kimi Code. Only Codex and Claude Code are current provider choices,
  and K3 is a model name rather than another provider.
- `status-line relay` is the separately confirmed local Claude integration.
  Hiding Claude is not the same as installing or removing this relay.
- `manual recovery` means the app refused an unsafe automatic restore. Do not
  soften it into retry succeeded or settings restored.
- `token activity` labels raw UTC activity dates. In zh-Hant:「不是帳務或計費資料」。
- `derived` and `partial` must remain visible when the app computes a subtotal
  from incomplete UTC rows.
- `not returned` must never be replaced by zero, none, or no usage.

## Translator note for UTC activity

Keys under `activity.*` describe UTC activity rows returned by Codex or a
clearly marked subtotal derived from those rows. Never rewrite them as billing,
invoicing, accounting, subscription, or authoritative account-usage claims.

Keys under `provider.*` and `status.provider.*` include dormant compatibility
source. Keys under `settings.claude_relay.*` describe the separately confirmed
Claude relay install/remove and recovery flow. They must not imply that the current
product boundary selects Google/Kimi, automatically installs a relay when Claude is shown, or
automatically removes one when Claude is hidden. Keep connection, presence,
quota capability, freshness, and recovery distinct; missing quota is never
translated as `0`, “none used,” or “unlimited.”
