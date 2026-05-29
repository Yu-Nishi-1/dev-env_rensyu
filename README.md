### 練習問題（AI指示）

「回答を生成する前に、以下のルールを厳守してください：
すぐに正解のTerraformコードを書かないでください。
まずは、私がこの課題を解くために作成すべき『ファイル構成』と、各ファイルで『どのdataソースやリソースを使うべきかという設計方針』のみを箇条書きで提示してください。
その後、私が1ファイルずつコードを提示するので、シニアSREの視点でレビューと修正アドバイスを行ってください。実務レベルの厳しい基準（保守性、疎結合、命名規則）でお願いします。」

---

### 【プロジェクト：bridge】要件定義

#### 1. 背景と目的

プラットフォームのマイクロサービス化に伴い、新規サービス追加時のインフラ作業依頼がリリース速度の制約となっている。サービス **bridge** は、既存基盤環境とエンドユーザーを接続する API 中継層として構築する。本プロジェクトの目的は、既存基盤の設定変更を回避し、開発チームによる自律的かつ安全な新規機能デプロイを完遂することにある。

さらに、複数のサービスを共通の仕組みでデプロイできる運用基盤（モノレポ＋再利用可能ワークフロー）を確立し、`bridge` をその最初のサービスとして載せる。リリース時のダウンタイムを抑えるため Blue/Green デプロイを採用し、練習環境のコストを抑えるため時間帯に応じたスケジュールスケーリングを行う。既存の安定稼働を維持しつつ、並行して新機能を迅速に市場へ投入できる柔軟なインフラを目指す。

#### 2. システムの役割

* **トラフィック制御**: 既存共通 ALB の背後に配置し、パス `/api/v2/*` へのリクエストを処理する。既存の Apache 基盤（Legacy App）へのトラフィックを阻害せず、特定パス配下のみを新環境へ動的にルーティングする。
* **データ参照**: 既存共有データベース（MySQL）からデータを取得し、新規ロジックを適用してレスポンスを生成する。既存のデータ整合性を保護しつつ、読み取りおよび特定の更新処理を bridge サービスから実行可能にする。
* **セキュリティ維持**: 既存 DB のセキュリティレベルを維持し、新規サービスに必要最小限のアクセス権限を動的に付与する。既存のセキュリティグループに直接変更を加えず、追加ルールの注入によって通信を制御する。
* **無停止デプロイ**: アプリ更新時は Blue/Green デプロイを行い、テストリスナー経由で新リビジョンを検証してから本番リスナーのトラフィックを切り替える。

#### 3. アーキテクチャ方針

既存基盤の整合性を保護しつつ、独立した実行環境を迅速に構築する。シングルコンテナ内で Web サーバーとアプリケーションを完結させ、疎結合な構成を実現する。Fargate の特性を活かしたスケーラビリティを確保し、コンテナイメージには実行に必要な最小限のバイナリのみを含めることで、起動時間の短縮と攻撃表面の削減を両立させる。構成管理はすべて Terraform で行い、環境ごとの差異は変数定義によって吸収する。

ランタイム（Nginx + PHP-FPM + PHP 拡張 + Composer）は、複数サービスで共有できる **ベースイメージ** として専用リポジトリで管理する。アプリイメージはこのベースイメージを `FROM` し、最小差分で構築する。これにより複数サービスがランタイムを共有でき、ビルド時間とメンテナンスコストを削減する。すべて Alpine Linux を基盤とし、軽量・最小構成を徹底する。

ネットワークは、コスト最適化およびセキュリティ強化の観点から、プライベートサブネット内のリソースが AWS サービス（S3・Secrets Manager・CloudWatch Logs・ECR 等）へインターネットを経由せずアクセスできるよう VPC Endpoint を構成する。可観測性（Observability）を担保するため、ログ・メトリクス・アラートの収集基盤を構築する。通信は可能な限り HTTPS を使用する。

ECS サービスは CodeDeploy による Blue/Green デプロイで更新する。CI/CD は、ビルド・デプロイ・マイグレーション・スケールといった各操作を再利用可能な Composite Action として部品化し、それらを再利用可能ワークフロー（template）から呼び出す。サービス・環境ごとの差異はトリガーワークフローと設定ファイル（conf）で吸収する。

#### 4. 技術的制約および遂行基準

* **イメージ最適化**: マルチステージビルドを使用し、実行用イメージにビルドツール（gcc, make 等）を含めないこと。
* **サイズ削減**: パッケージインストール後のキャッシュ（`apk cache` 等）を同一レイヤー内で削除すること。
* **イメージ二層化**: ランタイム層を「ベースイメージ（専用リポジトリ）」、アプリ層を「ベースイメージを `FROM` するアプリイメージ」に分離すること。すべて Alpine Linux ベースとすること。
* **セキュリティ**: `USER` 命令を用いて非特権ユーザー（UID:1000 等）でプロセスを実行すること。
* **権限管理**: アプリケーション実行ユーザーの書込権限を `storage/`, `bootstrap/cache/` のみに限定すること。
* **ポータビリティ**: 接続先情報等の機密情報をイメージに焼かず、ランタイム環境変数で注入可能にすること。
* **待ち受けポート**: コンテナ（Nginx）は **8080** で待ち受け、ALB ターゲットグループのポートも 8080 とすること。
* **ネットワーク**: プライベートサブネット内の ECS タスクが ECR や外部 AWS サービスへアクセスできるようにすること（VPC Endpoint）。
* **監視**: CloudWatch Logs を用いてアプリケーションおよびコンテナログを収集すること。
* **メトリクス**: ECS サービスの CPU・メモリ使用率を監視し、異常時にアラートを発報できるようにすること。
* **アラート閾値**: CloudWatch Alarm は CPU 使用率 70% 超過を閾値とすること。
* **可用性**: ECS サービスは単一インスタンスではなく、最小2タスク以上で稼働可能な設計とすること。
* **スケーリング**: CPU 使用率または ALB リクエスト数に基づいた Auto Scaling を構成すること。
* **デプロイ方式**: ECS サービスは `deployment_controller = CODE_DEPLOY` とし、Blue/Green 用にターゲットグループを2つ、本番リスナーとテストリスナーを用意すること。
* **マイグレーション**: デプロイ前に、稼働中サービスの task definition を取得し、`command` を `php artisan migrate --force` で override した単発タスク（`run-task`）として実行すること。失敗時はデプロイを中断すること。
* **セキュリティ（通信）**: ALB に HTTPS リスナー（443）を追加し、ACM 証明書を利用すること。
* **セキュリティ（防御）**: 必要に応じて AWS WAF の導入を検討すること。
* **CI/CD 共通化**: 各操作（ベースイメージビルド／アプリビルド／デプロイ／マイグレーション／スケール）をそれぞれ独立した Composite Action として部品化し、再利用可能ワークフロー（template）から呼び出すこと。サービス・環境別のトリガーワークフローと合わせて三層構成とすること。
* **設定の外部化**: 環境固有値（ECR リポジトリ名、ECS クラスタ／サービス／タスク定義名、CodeDeploy アプリ／グループ名、desired count、subnet / SG）は設定ファイル（`deploy.conf` / `base-build.conf`）に切り出し、スクリプトが `source` すること。
* **クロスリポジトリ認証**: ベースイメージ用リポジトリおよびアプリソース用リポジトリの checkout は GitHub App トークン（`actions/create-github-app-token`）で行うこと。AWS 認証は OIDC を用いること。
* **スケジュールスケーリング**: 時間帯（on-hours / off-hours）に応じて desired count を変更できるスクリプトとスケジュール実行を用意すること。production は 0 台にできない安全弁を設けること。
* **State 管理**: Terraform の状態管理は S3 バックエンドおよび DynamoDB ロックを用いること。

**シナリオ：既存「共通プラットフォーム」へのマイクロサービス追加構築**

あなたは、社内標準のインフラ基盤（Shared Platform）上に新規サービスをデプロイする担当者です。既存基盤側（VPC・DB・ALB）のコードには一切触れず、外部参照（data ソース）とルールの追加注入のみで、安全かつ保守性の高い環境を構築してください。さらに、この `bridge` を「複数サービス共通のデプロイ運用基盤」に載せ、無停止デプロイとコスト最適化を成立させてください。

---

#### 第１部：共通基盤の構築

**課題１：shared_platform の構築**

以下の仕様に従い、`shared_platform/` ディレクトリ配下の全ファイルを自分で作成してください。第２部以降の前提環境となります。

**ディレクトリ構成**
```
shared_platform/
├── main.tf            # プロバイダ、タグ設定
├── vpc.tf             # ネットワーク（VPC, Subnet）※NAT Gatewayなし
├── security_groups.tf # 全SGの集約定義（ALB / Legacy App / RDS）
├── alb.tf             # 共有ロードバランサー
├── network_ext.tf     # VPC Endpoint の構築
├── rds.tf             # 既存DB（RDS MySQL 8.0）
├── legacy_app.tf      # 既存メインサービス（Apache EC2）
└── outputs.tf         # my_new_service から参照する値の出力
```

**各ファイルの仕様**

| ファイル | 仕様 |
| :--- | :--- |
| **main.tf** | AWSプロバイダ（ap-northeast-1）。`default_tags` に `Scope = "SharedPlatform"`、`Environment = "common"`、`ManagedBy = "terraform"` を付与する。`required_version >= 1.5.0`、プロバイダバージョン `~> 5.0`。 |
| **vpc.tf** | VPC CIDR: `10.0.0.0/16`（`enable_dns_hostnames = true`）。パブリックサブネット2つ（1a: `10.0.101.0/24`、1c: `10.0.102.0/24`、`Type = "Public"` タグ）。プライベートサブネット2つ（1a: `10.0.1.0/24`、1c: `10.0.2.0/24`、`Type = "Private"` タグ）。**NAT Gateway は使用しない**（コスト最適化のため）。プライベートRTにはデフォルトルートを設定しない。legacy_web（EC2）の `dnf install` はカスタムAMIで対応する（後述のコスト最適化構成を参照）。RDS はVPC内完結のためインターネット通信不要。 |
| **security_groups.tf** | ALB用SG（80/443をインターネットから許可）。LegacyApp用SG（80をALB SGからのみ許可）。RDS用SG（3306をLegacyApp SGからのみ許可）。bridge サービス用の3306許可ルールは `my_new_service` 側から `aws_security_group_rule` で後付け注入する設計にすること。全SGをこのファイルに集約する。 |
| **alb.tf** | 共通ALB（パブリックサブネット2AZ配置）。Port 80 HTTPリスナー（デフォルト: 固定レスポンス200）。LegacyApp用ターゲットグループ（Port 80、ヘルスチェックパス: `/`）。リスナールール Priority 100、パス `*` → LegacyApp TGにフォワード。bridge サービスは Priority < 100 のルールを後から追加して `/api/v2/*` を先に捕捉させる。Blue/Green 用のテストリスナーは `my_new_service` 側から本 ALB に追加するため、`outputs.tf` で ALB ARN とリスナー ARN を出力しておく。 |
| **rds.tf** | RDS MySQL 8.0（`db.t3.micro`、gp2 20GB）。DB名 `app_db`、ユーザー `appuser`。プライベートサブネット2AZのサブネットグループ。`skip_final_snapshot = true`、`deletion_protection = false`（練習用途）。`utf8mb4` のパラメータグループを設定する。なお `users` テーブルの作成と初期データ（`taro`・`jiro`・`saburo`）の投入は、同一 VPC 内からアクセスできる `legacy_app.tf` の EC2 `user_data` 内で MySQL クライアントを使って行うこと（RDS はマネージドサービスのため `user_data` は使用不可）。`products` テーブルは bridge サービス側のマイグレーション（`php artisan migrate`）で管理するため、ここでは作成しない。 |
| **legacy_app.tf** | Amazon Linux 2023 EC2（`t3.micro`）をプライベートサブネット `private_1a` に配置。SGは `legacy_app` を使用。**カスタムAMIを使用すること**（`httpd`・`php`・`php-mysqlnd`・`mariadb105` がインストール済みのAMIを事前に作成し指定する。作成手順は後述のコスト最適化構成を参照）。`user_data` では `dnf install` を行わず、RDS の起動完了を待つリトライループ処理（`until mysql -h "$DB_HOST" -u appuser -papppass -e "SELECT 1;" 2>/dev/null; do sleep 5; done` 等）から開始すること。接続確認後に MySQL クライアントで `users` テーブル（`id INT AUTO_INCREMENT PRIMARY KEY`、`name VARCHAR(50) NOT NULL`）を作成し `taro`・`jiro`・`saburo` の初期データを投入する。続けて `/var/www/html/index.php` に DB から `users` テーブルを取得して `<h1>Legacy Main Application</h1>` を出力するスクリプトを配置する。**DB接続先は RDS の `address` を Terraform 参照で注入すること**（タグ名・ハードコード禁止）。ALBターゲットグループへの登録も行う。 |
| **network_ext.tf** | プライベートサブネット内のリソースが AWS サービスへインターネットを経由せずアクセスできるよう VPC Endpoint を構築する。既存環境で実際に使用しているサービスのみを対象とする。S3（Gateway型）、CloudWatch Logs（Interface型）。Interface型には専用SGを作成し、VPC CIDR からの443を許可する。 |
| **outputs.tf** | `vpc_id`、`private_subnet_ids`、`public_subnet_ids`、`alb_arn`、`alb_dns_name`、`alb_http_listener_arn`、`rds_sg_id`、`db_endpoint` を出力する。 |

**ネットワーク設計の考え方（重要）**

| リソース | インターネット通信 | 経路 |
| :--- | :--- | :--- |
| RDS | 不要 | VPC 内完結 |
| 新規サービス（第３部で追加） | AWS サービスのみ | VPC Endpoint（my_new_service側で追加） |
| Legacy App（EC2） | 不要（カスタムAMI使用） | ― |

**構築・動作確認手順**
```bash
cd shared_platform
terraform init
terraform apply

# LegacyApp の疎通確認
curl http://<ALB-DNS>/
# 期待値: "Legacy Main Application" を含む HTML が返ること
```

---

#### 第２部：コンテナイメージの定義（二層化）

新規サービス bridge を動かす、軽量でセキュアなコンテナイメージを「ベースイメージ」と「アプリイメージ」の二層で定義してください。すべて Alpine Linux ベースとします。

**アプリケーション要件**

* PHP 8.2 / Laravel 10系 / Alpine Linuxベース
* Nginx + PHP-FPM（Port 8080 待機）
* MySQL接続ドライバ、Composerインストール済み

**課題１：ベースイメージ（ランタイム層／専用リポジトリ）**

複数サービスで共有する PHP ランタイムを、アプリ本体とは別の専用リポジトリで管理します。第４部のベースビルド用 Composite Action からビルド・プッシュできるようにすることが目的です。

* **リポジトリ**: アプリ本体とは別の「コンテナ専用リポジトリ」（例: `project_bridge_container`）に置くこと。
* **配置**: `docker/alpine/Dockerfile` という階層に配置すること（環境やディストリビューションごとに切り出せる規約とする）。
* **内容**: Alpine ベースに、PHP 8.2、PHP-FPM、Nginx、MySQL 接続ドライバ（`pdo_mysql` 等）、Composer をインストール済みの状態にすること。アプリコードは含めず、ランタイムのみとすること。
* **最適化**: `apk` キャッシュを同一レイヤー内で削除し、ビルドツールを残さないこと。
* **タグ**: `base-build.conf` の `ECR_REPOSITORY` / `ECR_TAG` に従い、`:latest` と `:<short_hash>` の両方でプッシュする想定とすること（実際のプッシュは第４部の Composite Action が担当する）。

**課題２：アプリイメージ（アプリ層／環境別 Dockerfile）**

ベースイメージを土台に、アプリコードを載せた実行イメージを定義します。

* **配置**: `services/bridge/env/<environment>/Dockerfile`（環境ごとに差し替え可能）。ビルド時にサービスディレクトリ直下へコピーされる前提とすること。
* **ベース指定**: `FROM <アカウントID>.dkr.ecr.ap-northeast-1.amazonaws.com/<base-repo>:<tag>`（課題１のベースイメージ）とすること。
* **マルチステージ**: build ステージで `composer install --no-dev --optimize-autoloader`、production ステージで最小コピーとすること。
* **アプリコード取り込み**: アプリソース用リポジトリから checkout される `services/bridge/src/` と、共通の `shared/` を取り込むこと。
* **機密情報の完全分離**: Dockerfile 内に環境変数を焼き込まないこと。`config:cache` 等のビルド時制約を考慮した設計とすること。
* **.dockerignore**: `.git`、ローカルの `.env`、`vendor` 等の不要なファイルがイメージに含まれないよう適切に設定すること。
* **権限**: `storage`、`bootstrap/cache` への書き込み権限を付与し、`USER` 命令で非特権ユーザー（UID:1000 等）として実行すること。
* **ポート**: Nginx を 8080 で待ち受けること。
* **ヘルスチェック**: ALB ヘルスチェック（`/up` または `/health_check`）に応答すること。
* **Nginx 設定**: `.env` 等の機密ファイルへの外部アクセスを遮断すること（該当パスへのリクエストに 403 または 404 を返すこと）。

---

#### 第３部：新規サービスの構築（本番課題）

> **前提**: 第１部で構築した `shared_platform/` をここから先は「既存基盤」として扱う。そのコードには一切触れず、外部参照（data ソース）とルールの追加注入のみで構築すること。

本セクションでは、Laravel アプリケーションを AWS Fargate（ECS）上で CodeDeploy Blue/Green により稼働させるためのリソースを定義します。

**課題1：環境基盤と動的検索（provider.tf, data.tf, variables.tf）**

* `terraform.workspace` を使い、dev と prd でリソース名が衝突しないように命名を動的に制御する。
* VPC ID やサブネット ID を直書きせず、タグフィルタ（`Scope=SharedPlatform` や `Type=Private`）で data ソースから取得する。
* 既存の ALB リスナー ARN を variable で受け取り、data ソースで参照する。

**課題2：セキュリティの「外付け」注入（network.tf）**

* 新規サービス用の ECS セキュリティグループ（SG）を作成する。
* 既存の RDS 用 SG の ID を data で取得し、`aws_security_group_rule` を用いて、新規サービス用 SG からの 3306 通信を許可するルールを「後付け」で追加する。
* ECS タスクのアウトバウンド通信を制御し、不要な外部通信を制限すること。
* ECS Fargate が ECR からイメージを pull できるよう、Secrets Manager（Interface型）、ECR API（Interface型）および ECR DKR（Interface型）の VPC Endpoint を `network.tf` 内に追加すること。`shared_platform` 側の VPC Endpoint（S3・CloudWatch Logs）はそのまま共用できるため追加不要。

**課題3：パスベースルーティングと Blue/Green 用リスナー（alb.tf）**

* 既存の共有 ALB に、パス `/api/v2/*` を受け持つリスナールールを追加する。
* リスナールールの優先度（Priority）は variable で管理し、既存サービスと重ならないようにする。
* HTTPS リスナー（443）を追加し、HTTP から HTTPS へのリダイレクト設定を行うこと。
* ACM 証明書は DNS 検証を用いて発行すること。なお、DNS 検証レコードの実際の登録は省略してよい。`aws_acm_certificate` と `aws_acm_certificate_validation` の定義および `lifecycle { create_before_destroy = true }` の設定まで書けば合格とする。
* Blue/Green 用のターゲットグループを2つ作成すること（例: `bridge-<env>-tg-blue` / `bridge-<env>-tg-green`、いずれも Port 8080、ヘルスチェック `/up` または `/health_check`）。
* テストリスナーを追加すること（例: ポート 8443 等）。本番リスナー（443）とテストリスナーの ARN は CodeDeploy のデプロイグループから参照する。
* 本番リスナーの `/api/v2/*` ルールは初期状態で blue TG を向け、CodeDeploy が green への切替を行う前提とする。

**課題4：疎結合なシークレット管理（secrets.tf）**

* AWS Secrets Manager を作成し、DB パスワードなどを格納する。
* ECS のタスク定義内では、直接値を書かず、Secrets Manager の ARN を `valueFrom` で参照する。

**課題5：ECS Fargate の構築（ecs.tf）**

* ECS クラスター、タスク定義、サービスを構築する。
* `deployment_controller { type = "CODE_DEPLOY" }` を設定する（Blue/Green 用）。
* タスク定義には `lifecycle { ignore_changes = [cpu, memory] }` を設定し、運用の柔軟性を持たせる。スケジュールスケーリングおよび Auto Scaling との競合を避けるため、`desired_count` も `ignore_changes` の対象とすること。
* コンテナ定義は `.json.tftpl` ファイルを `templatefile` 関数で読み込む形式にする。コンテナ名は `bridge`、ContainerPort は 8080 とすること。
* CloudWatch Logs へのログ出力設定（awslogs ドライバ）を行うこと。
* サービスの `desired_count` は2以上とし、可用性を確保すること。
* Application Auto Scaling を用いて、CPU 使用率または ALB リクエスト数に応じたスケーリングを設定すること。
* CloudWatch Alarm（CPU 使用率 70% 超過）を `ecs.tf` 内に定義すること。
* マイグレーションは専用タスク定義を作らず、稼働中サービスの task definition を `aws ecs describe-services` で取得し、`command` を `php artisan migrate --force` で override した単発タスク（`run-task`）として実行する方式とすること（実行は第４部の CI/CD が担当する）。
* シーディング（初期データ投入）はマイグレーションとは分離し、初回のみ手動で `aws ecs run-task`（`command` を `db:seed` に override）で実行すること。

**課題6：CodeDeploy（codedeploy.tf）**

* `aws_codedeploy_app`（compute platform: ECS）を作成する。名前は `deploy.conf` の `CODEDEPLOY_APP_NAME` と一致させること。
* `aws_codedeploy_deployment_group`（ECS Blue/Green）を作成する。名前は `CODEDEPLOY_GROUP_NAME` と一致させること。
  * `deployment_style` は `BLUE_GREEN` ／ `WITH_TRAFFIC_CONTROL`。
  * `blue_green_deployment_config` で切替方式と旧タスク終了の待機時間を設定する。
  * `load_balancer_info` / `ecs_service` で、課題3の blue/green ターゲットグループと本番・テストリスナー、課題5の ECS クラスタ／サービスを紐付ける。
* `appspec.json` は CI/CD が動的生成する前提とし、Terraform では作成しない。

**課題7：CI/CD 連携と各種ロール（resource_iam.tf, outputs.tf）**

* ECS タスク実行ロール／タスクロール、CodeDeploy 用サービスロール、GitHub Actions OIDC 用ロールを定義する。
* ECR リポジトリを2つ `aws_ecr_repository` として定義する（アプリイメージ用＝`deploy.conf` の `ECR_REPOSITORY`、ベースイメージ用＝`base-build.conf` の `ECR_REPOSITORY`）。
* `outputs.tf` から以下を出力し、`deploy.conf` / `base-build.conf` に転記できるようにすること。
  * `ecr_repository_uri`（アプリ用）、`base_ecr_repository_uri`（ベース用）
  * `ecs_cluster_name`、`ecs_service_name`、`ecs_task_def_family`
  * `codedeploy_app_name`、`codedeploy_deployment_group_name`
  * `private_subnet_ids`（→ `VPC_SUBNETS`）、`ecs_security_group_id`（→ `VPC_SECURITY_GROUPS`）

**ディレクトリ構成**
```
my_new_service/
├── provider.tf      # 環境ごとの共通タグ・バックエンド設定
├── variables.tf     # パラメータ定義
├── data.tf          # 【課題1】既存基盤の検索定義
├── network.tf       # 【課題2】新規SG・既存SGへのルール追加・ECR用及びSecret Manager用VPC Endpoint追加
├── alb.tf           # 【課題3】共有ALBへのパスベースルーティング・Blue/Green用TG・テストリスナー
├── secrets.tf       # 【課題4】Secrets Managerの定義
├── ecs.tf           # 【課題5】ECSクラスター・サービス・タスク定義
├── codedeploy.tf    # 【課題6】CodeDeployアプリ・デプロイグループ
├── resource_iam.tf  # 【課題7】各種実行ロール・GitHub連携設定・ECRリポジトリ定義
├── outputs.tf       # 【課題7】デプロイに必要な情報の出力
└── container_def.json.tftpl  # 【課題5】ECSコンテナ定義テンプレート

env/
└── dev/
    ├── terraform.tfvars    # 開発環境用変数値
    └── terraform.tfbackend # S3バックエンド設定（key = env/dev/terraform.tfstate）
```

---

#### 第４部：デプロイ運用モノレポと CI/CD パイプライン

Laravelアプリのデプロイを GitHub Actions で自動化します。複数サービスを共通の仕組みで扱えるよう、インフラ定義（第３部）とは別リポジトリの「デプロイ運用モノレポ」として構築します。

設計の要は、**操作ごとに独立した Composite Action を部品として用意し、それらを再利用可能ワークフロー（template）から呼び出す**ことです。スクリプト（`prepare-*.sh` 等）は各 Composite Action の内部にラップし、ワークフローから直接は呼ばないようにします。

**ディレクトリ構成**
```
（deploy-monorepo）/
├── shared/                              # 全サービス共通コード（ビルド時に各サービスへコピー）
├── services/
│   └── bridge/
│       ├── src/                         # アプリソース用リポジトリから checkout される領域
│       └── env/
│           ├── develop/
│           │   ├── Dockerfile           # 第２部 課題2（アプリイメージ）
│           │   ├── deploy.conf          # デプロイ用設定
│           │   └── base-build.conf      # ベースビルド用設定
│           └── production/
│               └── …（同様）
└── .github/
    ├── actions/
    │   ├── base-build/action.yml        # Composite Action: ベースイメージのビルド＆プッシュ
    │   ├── build/action.yml             # Composite Action: アプリイメージのビルド＆プッシュ
    │   ├── deploy/action.yml            # Composite Action: CodeDeploy Blue/Green デプロイ
    │   ├── migration/action.yml         # Composite Action: マイグレーション単発実行
    │   └── scale/action.yml             # Composite Action: ECS スケール変更
    ├── scripts/
    │   ├── prepare-base-build.sh        # base-build.conf を読み出力に書き出す
    │   ├── prepare-docker-build.sh      # deploy.conf 読込、shared/ と Dockerfile をコピー
    │   ├── prepare-ecs-deploy.sh        # deploy.conf 読込、appspec.json を動的生成
    │   ├── run-migration.sh             # 稼働中タスク定義で migrate を単発実行
    │   └── ecs-scale.sh                 # スケジュールスケーリング
    └── workflows/
        ├── base-build-template.yml      # 再利用可能ワークフロー（base build）
        ├── base-build-bridge-dev.yml    # トリガー（service/env を指定して template を呼ぶ）
        ├── deploy-template.yml          # 再利用可能ワークフロー（build→migration→deploy）
        ├── deploy-bridge-dev.yml        # トリガー
        ├── scale-template.yml           # 再利用可能ワークフロー（scale）
        └── scale-bridge-dev.yml         # トリガー（schedule / 手動）
```

> ベースイメージの Dockerfile はこのモノレポではなく、別のコンテナ専用リポジトリ（第２部 課題1）に置く。アプリソースもまた別リポジトリにあり、いずれも Composite Action が GitHub App トークンで checkout する。

**課題1：設定ファイル（conf）の定義**

各スクリプトが `source` する。Terraform の出力値（第３部 課題7）から転記する。

`services/bridge/env/develop/base-build.conf`
```
ECR_REPOSITORY=<ベースイメージ用ECRリポジトリ名>
ECR_TAG=latest
```

`services/bridge/env/develop/deploy.conf`
```
ECR_REPOSITORY=<アプリイメージ用ECRリポジトリ名>
ECR_TAG=latest
ECS_CLUSTER_NAME=<terraform output>
ECS_SERVICE_NAME=<terraform output>
ECS_TASK_DEF_NAME=<terraform output>
CODEDEPLOY_APP_NAME=<terraform output>
CODEDEPLOY_GROUP_NAME=<terraform output>
DESIRED_COUNT=2
ON_HOURS_DESIRED_COUNT=2
OFF_HOURS_DESIRED_COUNT=0          # dev のみ 0 可。production は 0 禁止
VPC_SUBNETS=<private subnet ids カンマ区切り>
VPC_SECURITY_GROUPS=<ecs sg id>
```

**課題2：Composite Action 群（5種）の定義**

操作ごとに独立した Composite Action（`runs.using: composite`）を作成する。AWS 認証はいずれも OIDC（`aws-actions/configure-aws-credentials`、`role-to-assume`）で行う。

**`.github/actions/base-build/action.yml`（ベースイメージビルド）**

* `inputs`: `environment` / `service` / `branch`（コンテナリポジトリのブランチ）/ `app_id` / `app_private_key`。
* `actions/create-github-app-token` で一時トークンを生成 → `actions/checkout` でコンテナ専用リポジトリを checkout。
* short hash 取得 → OIDC 認証 → `aws-actions/amazon-ecr-login`。
* `prepare-base-build.sh` を実行して `ecr_repository` / `base_tag` / `registry` を取得。
* `docker/setup-buildx-action` → `docker/build-push-action` で `docker/alpine` をビルドし、`:<base_tag>` と `:<short_hash>` の両方をプッシュ。キャッシュは `type=gha`。

**`.github/actions/build/action.yml`（アプリイメージビルド）**

* `inputs`: `environment` / `service` / `branch`（アプリソースのブランチ）/ `app_id` / `app_private_key`。
* `actions/create-github-app-token` で一時トークンを生成 → `actions/checkout` でアプリソース用リポジトリを `services/<service>/src` に checkout。
* short hash 取得 → OIDC 認証 → `aws-actions/amazon-ecr-login`。
* `prepare-docker-build.sh` を実行（`shared/` と env 別 `Dockerfile` をサービスディレクトリ直下へコピー）し、`ecr_repository` / `base_tag` / `registry` を取得。
* `docker/build-push-action` でアプリイメージをビルドし、`:<base_tag>`（=latest 想定）と `:<short_hash>` の両方をプッシュ。

**`.github/actions/deploy/action.yml`（CodeDeploy Blue/Green デプロイ）**

* `inputs`: `environment` / `service` / `deploy_tag`（デプロイするイメージタグ）。
* OIDC 認証。
* `prepare-ecs-deploy.sh` を実行し、`image_name` / `ecs_cluster` / `ecs_service` / `ecs_task_def` / `container_name` / `codedeploy_app` / `codedeploy_group` / `appspec_path` を取得（`appspec.json` を動的生成）。
* `aws ecs describe-task-definition` で現行タスク定義を取得して JSON 化。
* `aws-actions/amazon-ecs-render-task-definition` で `container_name` のイメージを `image_name` に差し替えた新タスク定義を生成。
* `aws-actions/amazon-ecs-deploy-task-definition` で、生成タスク定義・`ecs_service`・`ecs_cluster`・`appspec_path`・`codedeploy_app`・`codedeploy_group` を指定し、`wait-for-service-stability: true` で CodeDeploy Blue/Green デプロイを実行。

**`.github/actions/migration/action.yml`（マイグレーション）**

* `inputs`: `environment` / `service` / `command`（JSON 配列）。
* OIDC 認証 → `run-migration.sh "<service>" "<environment>" '<command>'` を実行。
* スクリプト内では稼働中サービスの task definition を取得 → `command` を override して `run-task`（`assignPublicIp=DISABLED`、subnets / SG は conf）→ `wait tasks-stopped` → 終了コードを検証し、非 0 なら `::error::` で失敗させる。

**`.github/actions/scale/action.yml`（スケール変更）**

* `inputs`: `environment` / `service` / `schedule_type`（`on-hours` / `off-hours` / `manual`）。
* OIDC 認証 → `ecs-scale.sh "<service>" "<environment>" "<schedule_type>"` を実行。
* スクリプト内で conf の対応する desired count を選び `aws ecs update-service --desired-count` を実行。production を 0 にできない安全弁を持つ。

**課題3：再利用可能ワークフローとトリガー**

操作 Composite Action を呼び出す再利用可能ワークフロー（template）と、サービス・環境別のトリガーを用意する。

* `base-build-template.yml`（`on: workflow_call`）: `inputs: service / environment / branch`、`secrets: inherit`。内部で base-build Action を呼ぶ。`permissions: { contents: read, id-token: write }`。
* `base-build-bridge-dev.yml`（`on: workflow_dispatch`、`branch` 入力あり）: `uses: ./.github/workflows/base-build-template.yml` に `service: bridge` / `environment: develop` / `branch` を渡す。
* `deploy-template.yml`（`on: workflow_call`）: デプロイ本体（課題4）。
* `deploy-bridge-dev.yml`（`on: workflow_dispatch`）: `deploy-template.yml` を呼ぶ。
* `scale-template.yml`（`on: workflow_call`）: scale Action を呼ぶ。
* `scale-bridge-dev.yml`（`on: schedule` ＋ `workflow_dispatch`）: `scale-template.yml` を呼ぶ。
* 命名規約は `<操作>-template.yml`（再利用可能ワークフロー）と `<操作>-<service>-<env>.yml`（トリガー）とする。

**課題4：デプロイワークフローの処理順序**

`deploy-template.yml` は、課題2で作成した Composite Action を以下の順序で呼び出し、いずれかが失敗したら後続を中断すること。

1. **build Action**: アプリイメージをビルドし、`latest` と `${github.sha}`（= short hash 相当）の両方のタグで ECR にプッシュ。
2. **migration Action**: `command` に `["php","artisan","migrate","--force"]` を渡して実行。失敗（終了コード非 0）ならデプロイを中断。
3. **deploy Action**: `deploy_tag` に手順1のタグを渡し、`appspec.json` 動的生成 → タスク定義レンダリング → CodeDeploy Blue/Green デプロイ。
4. **デプロイ後ヘルスチェック**: `https://<ALB-DNS>/api/v2/status` 等へ疎通確認し、`database: OK` を検証。
5. シーディング（`db:seed`）は初回のみ手動で migration Action を `command: ["php","artisan","db:seed","--force"]` 等で実行し、通常デプロイでは行わない。

**課題5：スケジュールスケーリング**

`scale-template.yml` / `scale-bridge-dev.yml` と scale Action（課題2）、`ecs-scale.sh` で構成する。

* トリガー `scale-bridge-dev.yml` は `on: schedule`（cron）で、平日朝に `on-hours`、夜間に `off-hours` を template へ渡して実行すること（JST は UTC 換算に注意）。`workflow_dispatch` で `manual` も選べるようにすること。
* production を 0 台にしない安全弁を `ecs-scale.sh` 側で実装すること（`production` かつ `0` でエラー終了）。
* dev は `OFF_HOURS_DESIRED_COUNT=0` でコスト最適化、production は2台以上を維持すること。

---

#### Laravelアプリケーション側の準備

アプリソース用リポジトリに配置し、ビルド時に `services/bridge/src/` へ checkout される。

* **ファイル**: `database/migrations/xxxx_xx_xx_create_products_table.php`
    ```php
    // bridge サービス専用テーブルのマイグレーション定義
    // php artisan migrate --force で実行される
    public function up(): void
    {
        Schema::create('products', function (Blueprint $table) {
            $table->id();
            $table->string('name', 50);
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('products');
    }
    ```

* **ファイル**: `database/seeders/ProductSeeder.php`
    ```php
    // products テーブルの初期データ投入
    // 初回のみ手動で php artisan db:seed --class=ProductSeeder を実行する
    // デプロイのたびに実行しないこと
    public function run(): void
    {
        DB::table('products')->insertOrIgnore([
            ['id' => 1, 'name' => 'apple',  'created_at' => now(), 'updated_at' => now()],
            ['id' => 2, 'name' => 'banana', 'created_at' => now(), 'updated_at' => now()],
            ['id' => 3, 'name' => 'cherry', 'created_at' => now(), 'updated_at' => now()],
        ]);
    }
    ```

* **ファイル**: `routes/api.php`
    ```php
    // /api/v2/status でDB接続確認を返すエンドポイント
    Route::get('/v2/status', function () {
        try {
            DB::connection()->getPdo();
            return response()->json(['service' => 'bridge', 'database' => 'OK']);
        } catch (\Exception $e) {
            return response()->json(['service' => 'bridge', 'database' => 'NG', 'error' => $e->getMessage()], 500);
        }
    });

    // /api/v2/products でbridgeサービス専用テーブルのデータを返すエンドポイント
    // LegacyAppが参照する users テーブルとは異なるデータを返すことで
    // bridgeサービスが同一RDSから独自のデータを取得できていることを確認する
    Route::get('/v2/products', function () {
        try {
            $products = DB::table('products')->get();
            return response()->json(['service' => 'bridge', 'data' => $products]);
        } catch (\Exception $e) {
            return response()->json(['service' => 'bridge', 'error' => $e->getMessage()], 500);
        }
    });
    ```

---

#### 成果物（全47ファイル想定）

**第１部：shared_platform（8ファイル）**

* `shared_platform/main.tf`
* `shared_platform/vpc.tf`
* `shared_platform/security_groups.tf`
* `shared_platform/alb.tf`
* `shared_platform/network_ext.tf`
* `shared_platform/rds.tf`
* `shared_platform/legacy_app.tf`
* `shared_platform/outputs.tf`

**第２部：コンテナ関連（4ファイル）**

* ベースイメージ `docker/alpine/Dockerfile`（コンテナ専用リポジトリ）
* アプリイメージ `services/bridge/env/develop/Dockerfile`
* `.dockerignore`
* `shared/`（共通コード一式）

**第３部：Terraform 関連（11ファイル）**

* `my_new_service/provider.tf`
* `my_new_service/variables.tf`
* `my_new_service/data.tf`
* `my_new_service/network.tf`
* `my_new_service/alb.tf`
* `my_new_service/secrets.tf`
* `my_new_service/ecs.tf`
* `my_new_service/codedeploy.tf`
* `my_new_service/resource_iam.tf`
* `my_new_service/outputs.tf`
* `my_new_service/container_def.json.tftpl`

**Laravelアプリケーション関連（3ファイル）**

* `database/migrations/xxxx_xx_xx_create_products_table.php`
* `database/seeders/ProductSeeder.php`
* `routes/api.php`

**設定ファイル（2ファイル）**

* `services/bridge/env/develop/base-build.conf`
* `services/bridge/env/develop/deploy.conf`

**CI/CD - Composite Action（5ファイル）**

* `.github/actions/base-build/action.yml`
* `.github/actions/build/action.yml`
* `.github/actions/deploy/action.yml`
* `.github/actions/migration/action.yml`
* `.github/actions/scale/action.yml`

**CI/CD - スクリプト（5ファイル）**

* `.github/scripts/prepare-base-build.sh`
* `.github/scripts/prepare-docker-build.sh`
* `.github/scripts/prepare-ecs-deploy.sh`
* `.github/scripts/run-migration.sh`
* `.github/scripts/ecs-scale.sh`

**CI/CD - ワークフロー（6ファイル）**

* `.github/workflows/base-build-template.yml`
* `.github/workflows/base-build-bridge-dev.yml`
* `.github/workflows/deploy-template.yml`
* `.github/workflows/deploy-bridge-dev.yml`
* `.github/workflows/scale-template.yml`
* `.github/workflows/scale-bridge-dev.yml`

**その他（3ファイル）**

* `env/dev/terraform.tfvars`
* `env/dev/terraform.tfbackend`（S3バックエンド設定。`bucket`・`key`・`region`・`dynamodb_table` を定義。`key` は `env/dev/terraform.tfstate`）
* `Makefile`（`my_new_service/` 配下の Terraform 操作を対象に、`terraform init -backend-config=../env/dev/terraform.tfbackend` / `plan` / `apply` / `destroy` を `make` で実行できるよう共通化する）

---

### 完了条件（疎通確認仕様）

本プロジェクトにおけるインフラ構築の完了は、以下が確認できることをもって定義する。

1. **パスベースルーティングおよびDB接続確認**
    * **URL**: `[ALB-DNS]/api/v2/status`
    * **期待値**: `{"service": "bridge", "database": "OK"}` のJSON応答。
    * **検証目的**: `/api/v2/*` へのリクエストがbridgeサービスにルーティングされ、FargateコンテナからRDSへの接続が確立していること。

2. **bridgeサービスのDB連携確認**
    * **URL**: `[ALB-DNS]/api/v2/products`
    * **期待値**: HTTPステータス200、かつレスポンスボディが `{"service":"bridge","data":[...]}` の形式であり `data` 配列に1件以上のレコードが含まれること。
    * **検証目的**: ECS FargateタスクからRDSへのネットワーク疎通・認証・クエリ実行が完了し、結果をJSON形式で返却できること。

3. **既存サービス（Legacy）の維持確認**
    * **URL**: `[ALB-DNS]/`（ルートパス）
    * **期待値**: `Legacy Main Application` の文字列を含むHTML。
    * **検証目的**: 既存リスナールールの優先順位設定（Priority）が適切であり、既存環境を破壊していないことの確認。

4. **セキュリティ設定の有効性確認**
    * **URL**: `[ALB-DNS]/.env`
    * **期待値**: `403 Forbidden` または `404 Not Found`。
    * **検証目的**: Nginxの設定またはLaravelの配置が適切であり、機密情報ファイルへの外部アクセスが遮断されていることの確認。

5. **Blue/Green デプロイの確認**
    * デプロイワークフロー実行後、CodeDeploy のデプロイが `Succeeded` になり、本番リスナーのトラフィックが新リビジョン（green）へ切り替わっていること。テストリスナー経由で新リビジョンの `/api/v2/status` が `OK` を返すこと。

6. **マイグレーション中断制御の確認**
    * マイグレーションタスクの終了コードが 0 でない場合、デプロイが中断されること。

7. **スケジュールスケーリングの確認**
    * dev で `off-hours` 実行後に desired count が 0 になり、`on-hours` で 2 に戻ること。production で `off-hours`（0）を指定した場合にエラーで拒否されること。

---

### 練習環境のコスト最適化構成

本問題を練習環境（個人のAWSアカウント）で実施する場合、以下の構成でコストを月2,000円以内に抑えることができる。**本番環境では適用しないこと。**

#### 基本方針
- 作業時間中のみ `terraform apply` し、終了後は必ず `terraform destroy` を実行する
- dev は scale Action（`off-hours`）で ECS を 0 台にし、Fargate 稼働費をさらに削減する
- legacy_web（EC2）はNAT Gatewayを使わない設計のため、必要なパッケージを焼き込んだカスタムAMIを事前作成して使用する
- ベースイメージは一度プッシュすれば再利用できるため、変更時のみ base-build ワークフローを手動実行する
- ECRへのイメージプッシュはローカルから手動で行うこともできる

#### カスタムAMI作成手順

NAT Gatewayを使わない設計のため、`legacy_web` EC2は起動時に `dnf install` でインターネットへアクセスできない。そのため必要なパッケージをあらかじめ焼き込んだカスタムAMIを事前に作成しておく必要がある。手順は以下の通り。

1. **パブリックサブネットで一時EC2を起動**（Amazon Linux 2023、`t3.micro`）
2. **パッケージをインストール**
   ```bash
   sudo dnf install -y httpd php php-mysqlnd mariadb105
   ```
3. **AWSコンソールからAMIを作成**（EC2 → インスタンス → アクション → イメージとテンプレート → イメージを作成）
4. **一時EC2を終了**
5. **作成したAMIのIDを `legacy_app.tf` の `ami` に指定する**

#### ECS FargateのECRアクセス

ECS FargateからECRへのイメージpullは、第３部で `my_new_service` 側に Secrets Manager 用および ECR 用 VPC Endpoint（ECR API・ECR DKR）を追加することで対応する。`shared_platform` のVPC Endpoint（S3・CloudWatch Logs）はそのまま共用できる。ECRへのイメージプッシュをローカルから手動で行う場合は以下の通り。

```bash
aws ecr get-login-password --region ap-northeast-1 | docker login --username AWS --password-stdin <アカウントID>.dkr.ecr.ap-northeast-1.amazonaws.com
docker build -t bridge .
docker tag bridge:latest <ECR_URI>:latest
docker push <ECR_URI>:latest
```

#### コスト試算（1日3時間 × 20日稼働の場合）

| リソース | 月額概算 |
| :--- | :--- |
| RDS db.t3.micro | 約300円 |
| ALB | 約400円 |
| ECS Fargate（夜間0スケール込み） | 約80円 |
| VPC Endpoint × 2（shared_platform側） | 約60円 |
| VPC Endpoint × 3（my_new_service側・Secrets Manager、ECR用） | 約40円 |
| EC2 t3.micro | 約20円 |
| **合計** | **約900円** |
