# agent-sharedの定義

Definition version `2026-11-23`.

agent-sharedは、1つの配る元に置いたスキルとルールとhookを、利用者が使う各エージェントへ、そのエージェントが読む場所と形で置きます。
hookはClaude Codeのhookの形で1回だけ宣言し、エージェントの表が、各エージェントのファイルの置き場と読むイベントを示します。
置いたhookとルールの囲みには配る元を示す印が付くので、道具は自分が置いた物だけを外し、利用者が手で書いた物には触れません。
英語の[agent-shared.md](agent-shared.md)が正で、この頁はその日本語訳です。
語の意味は[GLOSSARY.ja.md](../GLOSSARY.ja.md)にあります。

## 全体

| ファイル | 書く人 | 中身 |
|---|---|---|
| `skills/<name>/SKILL.md` | 利用者 | Agent Skillsが定めるスキル |
| `rules/<name>.md` | 利用者 | Markdownのルールのファイル1つ |
| `hooks.json` | 利用者 | hookの宣言 |
| `agents.json` | 利用者 (無くてよい) | エージェントを足すか、エージェントの表の行を置き換える行 |
| エージェントの表 | この定義 | 各エージェントのファイルの置き場、読むイベント、確かめた版 |

```text
~/.shared/                     the person's own source folder
├── skills/plain-words/SKILL.md
├── rules/commit-messages.md
├── hooks.json                 the hook declaration
├── hooks/no-force-push.sh     a script a hook runs
└── agents.json                optional rows of the agent table
```

[examples/basic](../examples/basic)は、`agent-shared check`を通る配る元の例です。

## 配る元

配る元は、`skills/`と`rules/`と`hooks.json`のどれかを持つフォルダーです。

| 配る元 | 場所 | 認める手続き |
|---|---|---|
| 利用者自身の物 | `~/.shared` | 認めた扱い |
| 他の配る元 | `--source`で名指す任意のフォルダー | 利用者が1度認める |
| リポジトリの物 | リポジトリの根の`.shared` | 利用者が1度認める |

スキルのフォルダーの名前は、Agent Skillsの決まりどおり、その`SKILL.md`の`name`と同じにします。
ルールは`rules/`の直下の`.md`ファイルで、ファイル名がルールの名前です。
1回の実行の中で、2つの配る元が同じ名前のスキルかルールを持つ時は、何も書く前に断ります。

## hookの宣言

`hooks.json`は、Claude Codeの設定の`hooks`を持ちます。
イベントごとにグループの一覧を持ち、各グループは`matcher` (無くてよい) とhookの一覧を持ちます。

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/no-force-push.sh", "timeout": 5}
        ]
      }
    ]
  }
}
```

| 欄 | 意味 |
|---|---|
| `command` | エージェントが動かすシェルの命令。`${CLAUDE_PLUGIN_ROOT}`は配る元のpathに、リポジトリの中では`"$(git rev-parse --show-toplevel 2>/dev/null \|\| pwd)"/.shared`に置き換え、リポジトリのどのフォルダーからでも`.shared`を見つけられるようにする |
| `timeout` | 秒。Claude Codeと同じ読み方 |
| `tools` | エージェントの名前の一覧 (無くてよい)。そのエージェントにだけhookを置き、この欄そのものは書かない |

道具は、各hookをエージェントの表の全エージェントへ、そのエージェントの形で書きます。

- 行がhookのイベントを並べているエージェントには、宣言のままのhookを、命令に印を足して書く。
- 行がそのイベントを並べていないエージェントには書かず、実行の出力でhookとエージェントを名指す。
- hookのファイルの`version`を持つ行には、その数字をファイルの頭の`version`として書く。
- 同じファイルの同じイベントに、手で書いたhookが同じ命令を既に持つ時は置かず、断って名指す。

### 各エージェントの形

| エージェント | ルール | hook | 形 |
|---|---|---|---|
| Claude Code | `~/.claude/rules`にルールごとのリンク | `~/.claude/settings.json` | 宣言のまま |
| Codex | `~/.codex/AGENTS.md`の中の1つの囲み | `~/.codex/hooks.json` | 宣言のまま。置いた各hookにCodexの信頼の印も書く |
| GitHub Copilot CLI | `~/.copilot/copilot-instructions.md`の中の1つの囲み | `~/.copilot/hooks/agent-shared.json` | 宣言のままで、頭に`"version": 1`を置く。`copilot`の命令が`PATH`に在る時だけ書く (`needs_command`) |

スキルは、Claude Codeには`~/.claude/skills`へ、`~/.agents/skills`を読むエージェント (CodexとGitHub Copilot CLIを含む) にはそこへ置きます。

## エージェントの表

エージェントの表は[`src/agent_shared/agents.json`](../src/agent_shared/agents.json)として公開し、各道具は自分で表を持たずにこの1つを読みます。
`~/.shared/agents.json`に新しい名前の行を書くとエージェントが増え、公開した行と同じ名前の行を書くとその行を置き換えます。

| 欄 | 意味 |
|---|---|
| `name` | エージェントの名前。`tools`もこの名前を書く |
| `skills` | スキルごとのリンクを置くフォルダー。無い行はスキルを置かない |
| `repo_skills` | リポジトリの中で、そのリポジトリのスキルのリンクを置くフォルダー |
| `rules` | `place`と`form`。`link`は`place`のフォルダーにルールごとのリンクを置き、`block`は`place`のファイルの1つの囲みにルールを書く |
| `repo_rules` | `rules`と同じ。`place`はリポジトリの根からのpath |
| `hooks` | `file`にhookを書く。`version`はhookを持つファイルの頭に書く。`trust: codex-app-server`はCodexの信頼の印も書く |
| `repo_hooks` | `hooks`と同じ。`file`はリポジトリの根からのpath |
| `events` | エージェントが読むhookのイベント。無い行は全部のイベントを読む |
| `checked` | `command`は入っている版を出す命令、`from`と`to`はその行を確かめた一番低い版と一番高い版 |
| `needs` | 在る時だけその行を書くpath |
| `needs_command` | `PATH`に在る時だけその行を書く命令。飛ばした行のファイルからは今回の配る元の印を持つ物を外し、何も残らないファイルは消す |
| `plugins` | `claude`か`codex`。そのエージェントに入れたプラグインが既に持つスキルは、そのエージェントへ置かない |

```json
{"version": 1, "agents": [{"name": "My agent", "skills": "~/.my-agent/skills", "events": ["PreToolUse", "Stop"]}]}
```

## 印と記録

置いたhookは、命令の最後の行に印を持ちます。
印はシェルの注釈なので、エージェントは読み飛ばします。

```json
{"type": "command", "command": "bash /home/me/.shared/hooks/no-force-push.sh\n# agent-shared 1 source=3f9c2a71b0de", "timeout": 5}
```

置いたルールは、エージェントのルールのファイルの中で、2行の囲みの行に挟まれます。

```text
<!-- agent-shared begin source=3f9c2a71b0de -->
<!-- agent-shared rule commit-messages.md -->
# Commit messages
...
<!-- agent-shared end source=3f9c2a71b0de -->
```

| 置いた物 | 見分け方 |
|---|---|
| hook | 命令の最後の行の印`# agent-shared 1 source=<id>` |
| 1つのファイルに書いたルール | 同じ`<id>`を持つ始まりと終わりの囲みの行 |
| スキルかルールのリンク | リンクは印を持てないため、道具が自分で残す置いたリンクの記録 |

`<id>`は、配る元の実際のpathのSHA-256の頭の16進数12桁です。
道具は、自分が配る配る元の印を持つ物だけを外すか書き換え、それ以外には触れません。
物を外して空になったフォルダーは、その上で空になったフォルダーと合わせて消します。
家のフォルダーの直下のフォルダー (`~/.copilot`のようなエージェントのフォルダー) とリポジトリの根は、空でも残します。
リンクの記録と、1つのエージェントへ置かないと決めた物の一覧は各道具の物で、この定義には入りません。
agent-sharedは`placed.json`と`off.json`に持ちます。

## 配る元を認める

hookは命令を動かすので、道具は利用者が1度認めた配る元のhookだけを置きます。

- `~/.shared`は認めた扱い。
- 他の配る元は、初めての時に全部のhookの命令を利用者に見せ、利用者がyesと答えた時に認めた扱いになる。`agent-shared approve --source <folder>`がこれを行う。
- 認めていない配る元も、スキルとルールは置く。hookは1つも置かず、認める命令を実行の出力で名指す。
- Codexのようなエージェント自身の信頼の印は、置いたhookにだけ書く。
- 道具が認める手続きを持つ前から記録にあった配る元は、認めた扱い。

## Codexのプラグイン

`~/.shared/plugins.json`は、利用者がhookを信頼するCodexのプラグインを書きます。

| 欄 | 意味 |
|---|---|
| `codex.marketplaces` | マーケットプレイスの名前ごとに、Codexがそれを取ってくるgitのURL |
| `codex.plugins` | プラグイン。`codex.marketplaces`のマーケットプレイスを使い、それぞれ`<plugin>@<marketplace>`と書く |

- hookを信頼するとそのhookはどんな命令も動かせるので、道具は利用者自身の配る元である`~/.shared/plugins.json`だけを読む。他の配る元やリポジトリの`.shared`にある`plugins.json`は読まず、実行の出力で名指す。
- 実行のたびに、Codexに無いマーケットプレイスを登録し、Codexに無いプラグインを入れ、書いたプラグインの全てのhookに今の命令でCodexの信頼の印を書く。更新で変わったhookももう一度信頼される。
- 一覧から外したプラグインは入ったまま信頼も残る。`codex plugin remove <plugin>@<marketplace>`で消す。
- `agent-shared check`は、一番上がオブジェクトでない`plugins.json`、`<plugin>@<marketplace>`と書いていないプラグイン、マーケットプレイスが一覧に無いプラグイン、gitのURLが無いマーケットプレイスを断る。

## リポジトリへ置く

リポジトリの`.shared`はリポジトリ自身の中へ置くので、どのクローンにも同じ物が入ります。

| 置く物 | 場所 |
|---|---|
| スキル | 各行の`repo_skills`に、スキルごとの相対のリンク |
| ルール | 各行の`repo_rules`の1つの囲み。公開した表では`AGENTS.md` |
| hook | 各行の`repo_hooks`。`${CLAUDE_PLUGIN_ROOT}`は`"$(git rev-parse --show-toplevel 2>/dev/null \|\| pwd)"/.shared`に置き換える |

Codexは、利用者がCodexの中で信頼したリポジトリのhookだけを動かすので、実行の出力でCodexの`/hooks`を開くよう案内します。

## 全部を外す

道具は、1つの配る元が置いた物を、全エージェントから全部外せます。
外すのは、記録にあるリンク、その配る元の`<id>`を持つルールの囲みとhook、それらのhookへのエージェントの信頼の印です。
印と記録だけを頼りにするので、配る元のフォルダーを消した後でも外せます。
リポジトリの`.shared`では、リポジトリの中のファイルからも外します。
`agent-shared remove --source <folder>`がこれを行います。

## 配る元を確かめる

`agent-shared check --source <folder>`は、見つけた問題を`<file>: <entry>: <problem>`の形で1行ずつ出し、1つでもあれば終了コード1で終わります。

| 問題 | 名指す所 |
|---|---|
| 表のどのエージェントも読まないイベント | `hooks.<event>` |
| 命令を持たないhook | `hooks.<event>[<group>].hooks[<hook>]` |
| 配る元のエージェントの表の、名前の無い行 | `agents[<row>]` |
| 名前がフォルダーと違うスキル | `name` |

## 版

| 版 | 形 | 場所 |
|---|---|---|
| この定義 | 日付、`2026-11-23` | この文書の頭 |
| 印 | 整数、`1` | `# agent-shared 1 source=<id>` |
| エージェントの表 | 整数、`1` | `agents.json`の`version` |
| エージェント | そのエージェント自身の版 | その行の`checked` |

入っているエージェントの版がその行の`checked`の`from`より古い時、道具はそのエージェントへ何も書かず、前に置いた物をそのまま残し、そのことを知らせます。
版が`to`より新しい時と版を読めない時は、今までと同じに書き、そのことを知らせます。
エージェントは新しい版を頻繁に出し、新しい版はたいてい行を確かめた時の形を保つためです。

## 既にある仕様との関係

| 仕様か道具 | 扱う物 | この定義との関係 |
|---|---|---|
| Agent Skills | `SKILL.md`と、エージェントが読むスキルのフォルダー | スキルはAgent Skillsが定める形のまま置く |
| `AGENTS.md` | リポジトリの根の1つのルールのファイル | リポジトリのルールはその中の囲みに書く |
| Claude Codeのhook | hookの形とイベント | hookの宣言はこの形 |
| GitHub Copilot CLIとCodexのhook | Claude Codeの入れ子の形を読むhookのファイル | 宣言のまま書き、各エージェントが要る版と信頼の印を足す |
| Agent Plugins 1.0.0 | スキルとMCPを持ち運べるプラグイン。hookとルールは持ち運べない物として外している | ルールを持ち運べる部品にする案を`docs/proposals/agent-plugins-portable-rules.md`に書き、agentplugins/agent-plugins-spec#100として出した |
| Agent Plugins v1.1 | プラグインの根の`hooks.json`に、`command`と`args`で5つのイベントのhookを書く、持ち運べるhook | v1.1が出た後に、agent-sharedもこの形を配る元として読む(#25)。v1.1に無いイベントのためにClaude Codeの形も残す。エージェントの版ごとに読めるイベントの案を`docs/proposals/agent-plugins-hook-events.md`に書き、agentplugins/agent-plugins-spec#101として出した |
| rulesync、APM、AgentsMesh | 自分のhookの形を各エージェントの形へ直す道具 | それぞれの独自の形の代わりに、公開した1つの形と1つの印を渡す |
