# webui/static — 同梱しているファイル

| ファイル | 出所 | 用途 |
|---|---|---|
| `mermaid.min.js` | npm `mermaid@11.4.1` の `dist/mermaid.min.js`(MIT、`mermaid.LICENSE`) | `/docs/view` で ```` ```mermaid ```` を図にする |

CDN は使わない(`127.0.0.1` だけで完結させ、CSP も `script-src 'self'` のまま)。更新するときは `npm pack mermaid@<版>` で取り出して差し替え、上の版と sha256 を書き換える。

sha256(mermaid.min.js): a43bc1afd446f9c4cc66ac5dd45d02e8d65e26fc5344ec0ef787f88d6ddb6f9e
