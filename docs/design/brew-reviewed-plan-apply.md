# Homebrew helper の plan と apply の分割

`brew-reviewed-upgrade` (Formula) と `brew-reviewed-cask-upgrade` (Cask) を、承認の要らない検査をまとめる plan と、承認された plan だけを実行する apply に分ける設計です。Issue: #460。目的は、mise の更新 (ADR 0041、skill `tool-update`) と同じく、エージェントが候補を集めて提案し、ユーザーが承認し、承認された更新だけを実行する流れを、Homebrew でも実現することです (#462 の段階 2)。検査は、今と同じく helper が行います。

## 前提

### 今の流れ

どちらの helper も、1 回の実行で 1 つのパッケージを次の順に扱います。

| 段 | Formula | Cask |
|---|---|---|
| 1. 設定と認証の検査 | policy、developer mode、GitHub 認証 | policy、developer mode (GitHub の client は 6 の前に用意する) |
| 2. 対象の metadata | `load_target_metadata` | metadata の形、インストール済みの状態と receipt の snapshot |
| 3. smoke command の決定 | `br_select_check` (下記) | 同じ |
| 4. `brew update` | 実行し、名前が変わっていないことを確かめる | 実行し、名前が変わっていないことを確かめ、候補の snapshot を取る |
| 5. 更新の有無 | `brew outdated` | `brew outdated` |
| 6. cooldown | GitHub Release の公開日時 | Release と asset の時刻、asset の digest と Cask の checksum の一致 |
| 7. dry-run | `brew upgrade --dry-run` を表示 | 同じ |
| 8. 検証の範囲 | attestation を確かめる Formula の一覧。依存の metadata の検査 (`validate_dependency_metadata`) もここで行う | — |
| 9. 確認 | 端末で `[y/N]` | 端末で `[y/N]` |
| 10. 更新の直前の再確認 | — | インストール済みの状態、receipt、候補の snapshot が 2〜4 から変わっていないこと (`verify_pre_upgrade`) |
| 11. 更新 | attestation の検証 → `brew upgrade` | `brew upgrade --require-sha` |
| 12. 更新後の検査 | `brew vulns`、`brew linkage`、smoke command | 更新後の metadata、smoke command の対象、smoke command |

段 3 の `br_select_check` は、`-- COMMAND` が渡されず、Formula では `--no-check` もないときに動きます (`dot_local/lib/brew-reviewed-upgrade/common.sh` の `br_select_check`)。

- 保存済みの check があれば、それを試しに実行する (`br_probe`)。失敗しても自動検出には戻らず、下の手動の入力に進む。
- 保存済みの check がなければ、対象のコマンドを `--version`、`version` の順に試し、通った方を保存する。
- どちらでも決まらなければ、端末で入力を求める。端末がなければ終了コード 2 で止まる。

試しの実行に通った check は、その後で更新を見送ったり cooldown で止まったりしても保存されます。`-- COMMAND` で渡した command は今回限りで、更新の前には試さず、更新の後に一度だけ実行します (ADR 0026 の Amendment 2026-09-09)。壊れたツールを更新で直すときにも使えるようにするためです。

端末の入力を求めるのは 3 と 9 だけです。端末がないとき、9 は入力の終わりとして止まります。

### 決めごと

- 検査を弱めたり省いたりしない (ADR 0026)。
- 対話で使う今の 1 コマンドの流れは残す。plan と apply は、同じ検査の関数を使う。
- `HOMEBREW_NO_AUTO_UPDATE=1` (`dot_homebrew/brew.env`) により、`brew upgrade` は metadata を自分では更新しない。

### helper が防ぐ範囲

helper が防ぐのは、次の 2 つです。

- plan を作った後で、Homebrew の metadata、インストール済みの状態、Release、設定が変わったこと。
- 呼び出す側 (skill) の取り違え。別のパッケージの plan や、承認された後に作り直した plan を apply に渡すなど。

同じユーザー権限で動くプロセスが、わざと plan のファイルを書き換えたり、`brew` を並行して操作したりすることは、防ぐ範囲に含めません。そうしたプロセスは、helper を通さずに `brew upgrade` を直接実行できるので、helper では止められないからです。

## 設計

### コマンドの形

```sh
brew-reviewed-upgrade plan [--cooldown-exception REASON] [--no-check] FORMULA [-- COMMAND [ARG...]]
brew-reviewed-upgrade apply --plan PLAN_FILE --plan-sha256 HEX [--cooldown-exception REASON]

brew-reviewed-cask-upgrade plan [--cooldown-exception REASON] CASK [-- COMMAND [ARG...]]
brew-reviewed-cask-upgrade apply --plan PLAN_FILE --plan-sha256 HEX [--cooldown-exception REASON]
```

サブコマンドを付けない今の呼び方は、対話の流れとして残し、今と同じ段 1〜12 の順に進みます。

plan は JSON を stdout に、診断を stderr に出します。apply の出力は今と同じ人向けの表示です。

### 1. `brew update` は plan に含めない

`brew update` は metadata を更新するだけでなく、改名された Formula や Cask を移行します。新しい名前の Cask がすでにあれば、古い Cask をアンインストールします (#509 で Homebrew の実装を確認)。plan に含めると「plan は Formula も Cask も変更しない」を満たせないので、plan も apply も `brew update` を実行しません。`brew update` は、ユーザーが承認して実行する独立した段にします。

対話の流れは、今と同じく `brew update` を実行します。

metadata が新しいかどうかは、helper では判断せず、plan にも記録しません。plan の前に `brew update` を済ませるのは、呼び出す側の責任です。

### 2. plan の状態

plan は、次のどれかの状態を `status` として返します。どれも終了コード 0 です。検査に失敗したときは、JSON を出さずに 0 以外の終了コードで止まります。

| 状態 | 意味 | plan がどこで止まるか |
|---|---|---|
| `no_update` | 更新がない | 段 5 |
| `needs_check` | smoke command が決まらない | 段 5 の後 (下の 5 を参照) |
| `needs_exception` | cooldown の判定を通らず、例外もない | 段 6。今と同じく dry-run の前で止まる |
| `ready` | 段 1〜8 の検査をすべて通った | 最後まで |

`needs_exception` は、今の helper が「`--cooldown-exception` を付けて再実行」と案内して止まる場合のすべてに当たります。理由は `cooldown.blocked_by` に、次の種類で返します。

- `age`: 公開から待機時間がたっていない。`needs_exception` では、このときだけ `eligible_at` を返す。
- `draft`、`prerelease`: Release が draft、または prerelease。
- `unverified`: 公開日時や asset を確かめられない (GitHub の Release でない、asset の digest がない、など)。

skill は、`age` だけなら `eligible_at` まで待つ案を、それ以外なら例外を使うかの判断をユーザーに求めます。digest と checksum の不一致など、例外で通せない失敗は、今と同じく 0 以外の終了コードで止まります。

plan の中の順番は、段 1、2、4 の一部、5、smoke command の決定、6、7、8 です。段 4 では、`brew update` と、その前後で名前が変わっていないかの確認は行いません。Cask の候補の metadata の読み込みと snapshot は行います。`no_update` は smoke command を決める前に判定します。そのため、更新がないパッケージで「smoke command の選択が必要」と報告することはありません。

apply が受け付けるのは `ready` の plan だけです。

### 3. apply は plan を集め直して突き合わせる

apply は、plan のファイルにある検査の結果を判断の根拠にしません。承認された内容の記録として受け取り、同じ検査をすべてもう一度実行して、得られた plan と突き合わせます。plan のファイルから取るのは、ユーザーが plan に渡した入力 (下の「plan の入力」) だけです。

1. plan のファイルを一度だけ読み込み、その内容の SHA-256 が `--plan-sha256` と一致することを確かめる。以後は、読み込んだ同じ内容だけを使う。一致する前には、plan の中身を何も使わない。
2. `schema_version`、`kind` (`formula` / `cask`)、`status` が `ready` であることを確かめる。
3. plan と同じ関数で、plan と同じ段 (`brew update` を除く) をもう一度実行し、新しい plan を作る。入力は、plan を作ったときのものを plan のファイルから取る (下の「plan の入力」)。
4. 2 つの plan の「突き合わせる項目」が 1 つでも違えば止まる。
5. 一致すれば、smoke command を試し (下の 5 を参照)、段 10〜12 を今と同じに実行する。

plan の SHA-256 は、skill がユーザーに提案するときに見せ、承認された値を apply に渡します。plan のファイルの取り違えや、承認の後に作り直された plan は、ここで止まります。

#### plan の入力

apply の引数には、`-- COMMAND`、`--no-check`、対象の名前がありません。そこで plan は、自分が受け取った入力を `input` に記録し、apply は SHA-256 が一致した後で、そこから同じ入力を取って plan を作り直します。

- 対象の名前。
- `--no-check` を渡したか (Formula だけ)。
- `--cooldown-exception` を渡したか。理由の文面は記録せず、apply の引数で受け取る。
- `-- COMMAND` の argv。渡されたときのまま (コマンド名を解決する前) を記録する。apply は、今と同じ方法でコマンド名を解決し直し、解決した argv を plan と突き合わせる。PATH が変わって別のコマンドに解決されれば、突き合わせで止まる。

設定ファイル (保存済みの check、待機時間) は入力に含めません。apply は今の設定を読み直し、plan と突き合わせます。

突き合わせる項目は、時間で変わらないものに限ります。

| 項目 | Formula | Cask |
|---|---|---|
| 対象の名前と tap | ○ | ○ |
| インストール済みの version | ○ | ○ |
| 候補の version | ○ | ○ |
| 候補の checksum、URL | — | ○ (今の候補の snapshot) |
| インストール済みの状態と receipt | — | ○ (今の snapshot) |
| release notes の URL、Release の公開日時、draft と prerelease | ○ | ○ |
| Release と asset の個別の時刻、digest の照合の結果 | — | ○ |
| cooldown の待機時間の設定 | ○ | ○ |
| dry-run の出力 | ○ (正規化の要否は「未確定の点」) | ○ |
| attestation を確かめる Formula の一覧 | ○ | — |
| smoke command (argv、出どころ、自動検出の候補) | ○ | ○ |

`--no-check` と `--cooldown-exception` を渡したかは、apply が plan の `input` から取るので、作り直した plan とは必ず一致します。

cooldown の判定のうち、経過時間、通常の更新ができる日時、例外を実際に使ったか、例外で通した判定の種類は、時間がたつと変わるので突き合わせません。apply の時点でもう一度判定し、下の 4 の規則で通すかを決めます。

Cask の helper の段 10 (`verify_pre_upgrade`) は、apply の中でも残します。apply が plan を集め直した後から `brew upgrade` までの間の変化を見るためです。Formula の helper には今この段がないので、apply の 3〜4 がその役を兼ねます。

### 4. cooldown の例外は plan に記録し、理由は残さない

今の文書は、例外の理由をファイルに保存しないと決めています (shell history 以外に理由を残さないため)。この決めごとは変えません。

- plan は、`--cooldown-exception` を渡したか (`input`) と、例外で通した判定の種類 (`cooldown.exception_covers`、種類は上の `blocked_by` と同じ) を記録し、理由は記録しない。
- apply は、plan の `input` で `--cooldown-exception` が渡されていたときだけ `--cooldown-exception REASON` を受け付け、そのときは必ず求める。渡されていなかったのにフラグが渡されたら止まる。例外を実際に使ったかどうかでは決めない。
- apply で判定を通らなかった種類が、すべて plan の `exception_covers` に含まれていれば通す。含まれない種類があれば、例外があっても止まる。
- plan のときは `age` で例外を使い、apply のときには待機時間がたっていた場合は、今と同じく「例外は不要」と表示して先へ進む。
- digest と checksum の不一致は、今と同じく例外では通さない。
- 理由は、今と同じく画面に表示する。

例外が承認するのは、記録された種類の失敗を通すことです。apply で渡された理由の文面が plan のときと同じかどうかは、確かめません。

### 5. smoke command は plan で決め、試すのは apply

plan は端末の入力を求めず、command を実行せず、設定ファイルにも書きません。smoke command は、次のどれかで決め、argv と出どころを plan に書きます。

- `argument`: `-- COMMAND` での指定。今と同じく、パスを解決するだけで、更新の前には試さない。
- `saved_auto`: 自動検出で保存された check。今の対象のコマンドを指していることを確かめる。
- `saved_manual`: 手動で保存された check。パスを解決できることを確かめる。
- `auto`: 保存済みの check がなく、対象のコマンドが見つかるとき。候補の `--version`、`version` を、試す順に plan に書く。

保存済みの check は、自動検出か手動かを分けて記録し、突き合わせます。更新後に対象のコマンドを確かめるか (`br_verify_auto_check`) は、この出どころで決まるからです。plan の後で設定が書き換わり、同じ argv のまま出どころだけが変わった場合も、突き合わせで止まります。

次の場合、plan は `needs_check` を返し、理由を `check.problem` に書きます。

- `none`: 保存済みの check がなく、対象のコマンドも見つからない。
- `saved_auto_mismatch`: 自動検出で保存された check が、今の対象のコマンドを指していない。
- `saved_manual_unresolved`: 手動で保存された check のパスを解決できない。

今の helper は、保存済みの check が使えないとき、自動検出に戻らずに手動の入力を求めます。plan も、自分で別の check に変えません。ユーザーは、次のどれかで直してから plan をやり直します。

- 今回限りの check を `-- COMMAND` で指定する。
- `--forget-check` で保存済みの check を消し、自動検出に任せる。
- サブコマンドを付けない対話の流れで、check を入力し直す。

apply は、突き合わせが済んだ後、更新の前に、今の `br_probe` で smoke command を試します。試すのは `saved_auto`、`saved_manual`、`auto` だけです。`saved_auto` と `saved_manual` は、失敗したら止まります。直し方は、plan の `needs_check` と同じです。`auto` は候補を順に試し、通ったものを保存します。どれも通らなければ止まります。`argument` は、今と同じく更新の前には試さず、更新の後に一度だけ実行します。

設定ファイルに書くのは apply だけです。そのため、今の helper と違い、plan で止まったり apply を実行しなかったりした場合は、自動検出した check は保存されません。

`--no-check` (Formula だけ) も plan に記録します。`--no-check` を付けたときは smoke command を決めないので、`needs_check` にもなりません。apply は、plan に書かれた smoke command と `--no-check` だけを使い、自分では選び直しません。自動検出の check (`saved_auto`、`auto`) が更新後も対象のコマンドを指しているかの確認 (`br_verify_auto_check`) は、今と同じく残します。実行するかどうかは、突き合わせで一致した出どころで決めます。

### 6. apply は端末の入力を読まない

apply は、引数を読んだ後に stdin を `/dev/null` につなぎ替えます。そのため、`brew upgrade`、smoke command などの子プロセスが stdin から入力を求めても、待たずに失敗します。bats では、stdin を読む smoke command の fixture で、apply が止まらずに失敗することを確かめます。

制御端末がある環境では、子プロセスが `/dev/tty` を開いて入力を求めることができます (`sudo` のパスワードなど)。stdin のつなぎ替えでは、これは防げません。apply を制御端末から切り離す方法は、macOS に標準の手段がないので、v1 では入れません。

その代わり、apply は制御端末がないことを実行の条件にします。引数を読んだ直後、plan のファイルを読む前に `/dev/tty` を開けるかを確かめ、開けたらエラーで止まります。端末から自分で更新するときは、サブコマンドを付けない対話の流れを使います。判定は 1 つの関数にまとめ、bats ではその関数を差し替えて、端末があるときに止まることと、ないときに進むことを確かめます。

### 7. plan は 1 つのパッケージずつ

plan も apply も、1 回の実行で 1 つのパッケージだけを扱います。候補の一覧は、skill が `brew outdated --json=v2` で集め、パッケージごとに plan を呼んで作ります。一度に複数を扱う必要が分かったら、そのときに足します。

### plan の JSON

```json
{
  "schema_version": 1,
  "kind": "cask",
  "status": "ready",
  "token": "codex",
  "input": {"target": "codex", "no_check": false, "cooldown_exception": false, "command": null},
  "tap": "homebrew/cask",
  "installed_version": "1.2.3",
  "candidate_version": "1.2.4",
  "release": {
    "notes_url": "https://github.com/...",
    "published_at": "2026-11-20T00:00:00Z",
    "draft": false,
    "prerelease": false
  },
  "cooldown": {
    "hours": 48,
    "eligible_at": "2026-11-22T00:00:00Z",
    "blocked_by": [],
    "exception_covers": []
  },
  "dry_run": "...",
  "verification": {"attested_formulae": []},
  "check": {"origin": "saved_auto", "argv": ["/opt/homebrew/bin/codex", "--version"]},
  "snapshots": {"installed_state": {}, "installed_receipt": {}, "candidate": {}}
}
```

`ready` 以外の状態では、その状態を決めた段までの項目だけを返します。たとえば `no_update` は対象の名前と version だけ、`needs_exception` は `cooldown` (`blocked_by`、`age` のときは `eligible_at`) までを返し、`dry_run` を含みません。`auto` の check は、`argv` の代わりに試す順の候補 (`candidates`) を返します。`needs_check` の check は、`argv` の代わりに `problem` を返します。

plan のファイルは、呼び出す側が権限 0600 の一時ファイルに保存します。ファイルには secret を含めません (cooldown の例外の理由を記録しないのはこのためです)。

## helper では防げないこと

- **承認の内容と plan の対応。** helper が確かめるのは、apply に渡された plan が SHA-256 で指定されたものであり、今の状態と一致することです。その plan がユーザーの承認したパッケージのものかどうかは確かめられません。これは skill で守ります。skill は、ユーザーに見せた plan のファイルと SHA-256 をそのまま apply に渡し、plan の名前と version を承認の内容と照らし合わせます。apply は `input` の `no_check`、`cooldown_exception`、`command` に従うので、skill はこれらも承認のときにユーザーに見せます。
- **同じ version のまま中身が差し替わること (Formula)。** 突き合わせは version で行うので、同じ version のまま bottle が差し替わっても気づきません。更新する bottle は、今と同じく attestation の検証で確かめます。
- **検査から `brew upgrade` までの間の変化。** `brew upgrade` は名前で候補を決め直すので、検査が済んでから更新が始まるまでに metadata が変われば、検査していない候補が入りえます。これは今の helper にもある隙間で、plan と apply に分けて新しく生まれたものではありません。`HOMEBREW_NO_AUTO_UPDATE=1` があるので、変わるのは誰かが並行して `brew update` を実行したときに限られ、その操作は防ぐ範囲の外です。

## 進め方

1. この設計を Codex にレビューしてもらう (初回は済み。指摘を反映し、修正の確認を 1 回行う)。
2. Cask の helper で plan と apply を作る。更新の直前に再確認する仕組みがすでにあり、変更が小さいので、形を試すのに向いている。価値が大きいのは Formula の方 (Cask の helper で扱える Cask は今 2 件) だが、先に小さい方で形を固める。
3. plan の JSON の形と共通の処理を `dot_local/lib/brew-reviewed-upgrade/common.sh` にまとめ、Formula の helper に広げる。
4. `docs/homebrew-update.md` と bats のテストを、それぞれの PR で更新する。

## 未確定の点

- **dry-run の出力が毎回同じか。** 今は文字列をそのまま表示しています。同じ状態で 2 回実行して同じ出力になるかは、macOS でまだ確かめていません (この Linux の環境では、sandbox の中で書き込み権限が足りず、dry-run を実行できませんでした)。違うなら、突き合わせの前に正規化する必要があります。
- **端末なしで更新が通るか。** `brew upgrade` が、stdin を `/dev/null` にした状態で最後まで進むかを、macOS で確かめていません (Cask では、アプリによっては管理者のパスワードを求めることがあります)。通らないものは、apply では止まって報告します。あわせて、エージェント (Claude Code の Bash など) から実行したときに制御端末がないことを確かめます。制御端末があれば、apply は条件を満たさずに止まるだけで、更新はしません。その場合は、apply を制御端末から切り離す方法を検討し直します。
- **apply が plan を集め直すときの GitHub API の呼び出し。** plan と apply で 2 回呼ぶことになります。rate limit に触れるかは、使ってみて確かめます。
