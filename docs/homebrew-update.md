# Homebrew 更新手順

この手順書は、未確認の更新を普段使いの環境へ偶然取り込まず、通常更新を確認後に個別適用するためのものです。方針の根拠は [ADR 0026](adr/0026-development-update-policy.md)、開発環境全体のセキュリティ方針は [security.md](security.md) を参照してください。

## 管理設定

`~/.homebrew/brew.env` は Homebrew 更新ポリシーの正本です。Homebrew 自身がこのファイルを読むため、interactive shell 以外からの実行にも適用されます。

| 設定 | 効果 |
| --- | --- |
| `HOMEBREW_NO_AUTO_UPDATE=1` | `install` 前の暗黙的な `brew update` を止める |
| `HOMEBREW_NO_INSTALL_UPGRADE=1` | `brew install <name>` の再実行による既存packageの更新を止める |
| `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1` | 指定外のdependentの自動upgrade/reinstallを止める |
| `HOMEBREW_CASK_OPTS=--require-sha` | checksumのないCaskを拒否する |
| `HOMEBREW_UPDATE_TO_TAG=1` | Homebrew本体を最新`main`ではなく最新stable tagへ更新する |
| `HOMEBREW_VERIFY_ATTESTATIONS=1` | `homebrew/core` Bottleのbuild provenanceを`gh`で検証する |

有効状態は次で確認します。

```sh
brew developer state
brew config
gh auth status
```

`brew developer state` はdisabledか、少なくとも`HOMEBREW_UPDATE_TO_TAG`によりstable tagへ更新すると表示される必要があります。Bottle attestationには有効なGitHub CLI認証が必要です。

## 通常のFormula更新

通常更新は公開から7日を目安に保留します。security advisory、active exploit、作業を復旧するbreak/fixはこの待機期間を省略します。

```sh
# Homebrew本体をstable tagへ、package metadataを最新状態へ更新する
brew update

# 通常対象と、自己更新/:latestを含むCaskの記録を別々に確認する
brew outdated --verbose
brew outdated --greedy --verbose

# 例: ripgrepだけを確認して更新する
brew upgrade --dry-run ripgrep
brew vulns --deps ripgrep
brew verify --deps ripgrep
brew upgrade ripgrep

# 更新後のlinkageと対象コマンドを確認する
brew linkage --test
rg --version

# brew verifyが有効化したdeveloper modeを更新セッションの最後に戻す
brew developer off
brew developer state
```

`brew upgrade --dry-run` に表示されたtargetとdependencyをすべて確認してから更新します。引数なしの`brew upgrade`は使用しません。

`brew vulns` はFormula名とversionをOSV APIへ送信し、Caskは検査しません。外部送信が許可される環境でのみ実行してください。`brew verify` は対象Bottleをdownloadし、GitHubのattestation APIへ照会します。検証対象は`homebrew/core`のBottleであり、Cask、third-party Tap、source buildは対象外です。

現行Homebrewでは`brew verify`はdeveloper commandであり、実行するとdeveloper modeが有効になります。`HOMEBREW_UPDATE_TO_TAG=1`により`brew update`は引き続きstable tagを選びますが、状態を明確に保つため更新セッションの最後に`brew developer off`を実行します。

## dependentの修復

`~/.homebrew/brew.env` は継承したshell環境より後に読み込まれるため、`env -u HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`では設定を解除できません。指定外packageを自動更新する経路へ戻さず、失敗したdependentを個別に確認します。

```sh
brew linkage --test
brew upgrade --dry-run <dependent>
brew upgrade <dependent>

# linkageだけが壊れていてversion更新が不要な場合
brew reinstall <dependent>
```

各dependentについてrelease notesとdry-runを確認し、まとめてではなく名前を指定して修復します。

## 高権限CLI

資格情報、source code、container、input monitoringへ触れるCLIやCaskは、通常packageより慎重に扱います。例: `codex`、`gh`、`op`、cloud CLI、container tooling、`karabiner-elements`、editor。

更新前にrelease notes、publisher、version、変更範囲を確認します。pinする場合は少なくとも四半期ごとにsecurity updateを確認し、長期間放置しません。`git`、`curl`、`openssl`、`ca-certificates`などのsecurity-sensitive libraryは長期pinしません。

## Cask

Caskはvendorがbuildしたartifactをinstallします。次の情報を確認します。

```sh
brew info --cask --json=v2 <cask> \
  | jq '.casks[0] | {token, version, sha256, auto_updates}'
```

- `auto_updates: true`: アプリ自身の更新機構がHomebrew外で動く可能性がある
- `version: latest`: Homebrewが固定versionを追跡できない
- `sha256: no_check`: download内容を固定checksumで検証できない

版を管理したいCaskはアプリ側の自動更新も無効にします。`--require-sha`で拒否されたCaskは設定を一時解除してinstallせず、vendor配布物として署名主体、配布URL、release notesを別途レビューします。

## third-party Tap

Tap全体ではなく必要なFormula、Cask、commandだけをtrustします。

```sh
brew tap
brew trust --json=v1
brew trust --formula vendor/tap/tool
brew install vendor/tap/tool
```

不要になった個別trustは`brew untrust --formula vendor/tap/tool`で削除します。Tap全体のtrustは、そのTapの現在および将来の全定義を信頼する必要がある場合に限ります。

## attestation失敗時

検証失敗をpackageの正常性とみなして続行しません。まず認証と対象を確認します。

```sh
gh auth status
brew verify --deps <formula>
```

`gh`が未導入または壊れている場合、`gh`自身はHomebrewのbootstrap例外としてattestation対象外です。`brew install gh`で復旧し、`gh auth login -h github.com`後に`brew verify gh`を実行します。検証後は成功・失敗にかかわらず`brew developer off`でdeveloper modeを戻します。`HOMEBREW_NO_VERIFY_ATTESTATIONS=1`による一時無効化は、`gh`bootstrapや障害切り分けに限定し、他Formulaの通常更新を通す目的では使用しません。

## Homebrew developer modeからの移行

一度だけ次を実行します。

```sh
brew developer off
brew update
brew developer state
brew --version
```

`brew developer state`がdisabled、`brew --version`がcommit数付きの`main`表記ではなくstable versionになっていることを確認します。この操作はinstalled Formula/Caskをupgradeしません。
