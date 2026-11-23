# 用語集

agent-sharedの定義で使う語です。[GLOSSARY.md](GLOSSARY.md)が正で、この頁はその日本語訳です。

| 語 | 意味 |
|---|---|
| 配る元 (source folder) | `skills/`と`rules/`と`hooks.json`を持ち、道具がその中身を各エージェントへ置くフォルダー。`~/.shared`は利用者の物で、リポジトリは`.shared`に持つ |
| hookの宣言 (hook declaration) | 配る元の`hooks.json`に、Claude Codeのhookの形で1回だけ書いたhook |
| エージェントの表 (agent table) | 各エージェントがスキルとルールとhookを置く場所、読むhookの形、イベント名と欄の対応、確かめたエージェントの版を並べたJSONの表 |
| 印 (mark) | 置いたhookの命令の最後の行`# agent-shared 1 source=<id>`。どの配る元が置いたかを示す。数字は印の形の版 |
| ルールの囲み (rules block) | エージェントのルールのファイルの中で、`<!-- agent-shared begin source=<id> -->`と`<!-- agent-shared end source=<id> -->`に挟まれた行。1つの配る元が置いたルールを持つ |
| 認めた配る元 (approved source) | 本人が1度hookを認めた配る元。`~/.shared`は認めた扱いで、道具は認めていない配る元のhookを書かない |
| 記録 (record) | リンクには印を書けないため、道具が自分で置いたリンクを残すファイル。agent-sharedは`placed.json`に持つ |
| 切る一覧 (switch list) | 1つの配る元の物を1つのエージェントへ置かないと決めた一覧を、道具が自分で持つファイル。agent-sharedは`off.json`に持つ |
