### 練習問題(AI指示)

「回答を生成する前に、以下のルールを厳守してください：
すぐに正解のTerraformコードを書かないでください。
まずは、私がこの課題を解くために作成すべき『ファイル構成』と、各ファイルで『どのdataソースやリソースを使うべきかという設計方針』のみを箇条書きで提示してください。
その後、私が1ファイルずつコードを提示するので、シニアSREの視点でレビューと修正アドバイスを行ってください。実務レベルの厳しい基準（保守性、疎結合、命名規則）でお願いします。」

### 【プロジェクト：bridge】要件定義の再構築

#### 1. 背景と目的
プラットフォームのマイクロサービス化に伴い、新規サービス追加時のインフラ作業依頼がリリース速度の制約となっている。サービス **bridge** は、既存基盤環境とエンドユーザーを接続するAPI中継層として構築する。本プロジェクトの目的は、既存基盤の設定変更を回避し、開発チームによる自律的かつ安全な新規機能デプロイを完遂することにある。既存の安定した稼働を維持しつつ、並行して新機能を迅速に市場へ投入するための柔軟なインフラストラクチャを確立する。

#### 2. システムの役割
* **トラフィック制御**: 既存共通ALBの背後に配置し、パス `/api/v2/*` へのリクエストを処理する。既存のApache基盤（Legacy App）へのトラフィックを阻害せず、特定のパス配下のみを新環境へ動的にルーティングする。
* **データ参照**: 既存共有データベース（MySQL）からデータを取得し、新規ロジックを適用してレスポンスを生成する。既存のデータ整合性を保護しつつ、読み取りおよび特定の更新処理を bridge サービスから実行可能にする。
* **セキュリティ維持**: 既存DBのセキュリティレベルを維持し、新規サービスに対して必要最小限のアクセス権限を動的に付与する。既存のセキュリティグループに直接変更を加えず、追加のルール注入によって通信を制御する。

#### 3. アーキテクチャ方針
既存基盤の整合性を保護しつつ、独立した実行環境を迅速に構築する。シングルコンテナ内でWebサーバーとアプリケーションを完結させ、疎結合な構成を実現する。Fargateの特性を活かしたスケーラビリティを確保し、コンテナイメージには実行に必要な最小限のバイナリのみを含めることで、起動時間の短縮と脆弱性への攻撃表面の削減を両立させる。構成管理はすべてTerraformで行い、環境ごとの差異は変数定義によって吸収する。
ネットワーク設計においては、コスト最適化およびセキュリティ強化の観点から、プライベートサブネット内のリソースが AWS サービス（S3・Secrets Manager・CloudWatch Logs等）へインターネットを経由せずアクセスできるよう VPC Endpoint を構成する。
可観測性（Observability）を担保するため、ログ、メトリクス、アラートの収集基盤を構築すること。
通信は可能な限りHTTPSを使用し、セキュリティを確保する。

#### 4. 技術的制約および遂行基準
* **イメージ最適化**: マルチステージビルドを使用し、実行用イメージにビルドツール（gcc, make等）を含めないこと。
* **サイズ削減**: パッケージインストール後のキャッシュ（`apk cache` 等）を同一レイヤー内で削除すること。
* **セキュリティ**: `USER` 命令を用いて非特権ユーザー（UID:1000等）でプロセスを実行すること。
* **権限管理**: アプリケーション実行ユーザーの書込権限を `storage/`, `bootstrap/cache/` のみに限定すること。
* **ポータビリティ**: 接続先情報等の機密情報をイメージに焼かず、ランタイム環境変数で注入可能にすること。
* **ネットワーク**: プライベートサブネット内のECSタスクがECRや外部AWSサービスへアクセスできるようにすること（VPC Endpoint）。
* **監視**: CloudWatch Logs を用いてアプリケーションおよびコンテナログを収集すること。
* **メトリクス**: ECSサービスのCPU・メモリ使用率を監視し、異常時にアラートを発報できるようにすること。
* **アラート閾値**: CloudWatch Alarm は CPU使用率70%超過を閾値とすること。
* **可用性**: ECSサービスは単一インスタンスではなく、最小2タスク以上で稼働可能な設計とすること。
* **スケーリング**: CPU使用率またはALBリクエスト数に基づいたAuto Scalingを構成すること。
* **セキュリティ（通信）**: ALBにはHTTPSリスナーを追加し、ACM証明書を利用すること。
* **セキュリティ（防御）**: 必要に応じてAWS WAFの導入を検討すること。
* **State管理**: Terraformの状態管理はS3バックエンドおよびDynamoDBロックを用いること。

**シナリオ：既存「共通プラットフォーム」へのマイクロサービス追加構築**
あなたは、社内標準のインフラ基盤（Shared Platform）上に、新規サービスをデプロイする担当者です。既存基盤側（VPC、DB、ALB）のコードには一切触れず、外部参照（dataソース）とルールの追加注入のみで、安全かつ保守性の高い環境を構築してください。

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
| **alb.tf** | 共通ALB（パブリックサブネット2AZ配置）。Port 80 HTTPリスナー（デフォルト: 固定レスポンス200）。LegacyApp用ターゲットグループ（Port 80、ヘルスチェックパス: `/`）。リスナールール Priority 100、パス `*` → LegacyApp TGにフォワード。bridge サービスは Priority < 100 のルールを後から追加して `/api/v2/*` を先に捕捉させる。 |
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

#### 第２部：機能要件

**課題１：Dockerfileの作成**
新規サービス bridge を動かすための、軽量でセキュアなコンテナイメージを定義してください。

**アプリケーション要件**
・PHP 8.2 / Laravel 10系 / Alpine Linuxベース
・Nginx + PHP-FPM（Port 80待機）
・MySQL接続ドライバ、Composerインストール済み

**Dockerfile上の以下ベストプラクティスに準拠すること**
・ビルド用ステージと実行用ステージを分けること（buildステージでcomposer install --no-dev、productionステージで最小化コピー）。
・機密情報の完全分離（Dockerfile内に環境変数を焼き込まない。config:cache等のビルド時制約を考慮した設計）
・.dockerignore を適切に設定し、不要なファイル（.git やローカルの .env、vendor など）がイメージに含まれないようにすること。
・ALBヘルスチェック（/up または /health_check）への応答
・適切なディレクトリ権限設定（storage, bootstrap/cacheへの書き込み権限）
・実行ユーザーの制限：コンテナ内プロセスを root ではなく一般ユーザーで実行すること。
・Nginx の設定で `.env` 等の機密ファイルへの外部アクセスを遮断すること（該当パスへのリクエストに 403 または 404 を返すこと）。

---

#### 第３部：新規サービスの構築（本番課題）

> **前提**: 第１部で構築した `shared_platform/` をここから先は「既存基盤」として扱う。そのコードには一切触れず、外部参照（data ソース）とルールの追加注入のみで構築すること。

本セクションでは、LaravelアプリケーションをAWS Fargate（ECS）上で稼働させるためのリソースを定義します。

**課題1：環境基盤と動的検索 (provider.tf, data.tf, variables.tf)**
・terraform.workspace を使い、dev と prd でリソース名が衝突しないように命名を動的に制御する。
・VPC IDやサブネットIDを直書きせず、タグフィルタ（Scope=SharedPlatform や Type=Private）で data ソースから取得する。
・既存のALBリスナーARNを variable で受け取り、data ソースで参照する。

**課題2：セキュリティの「外付け」注入 (network.tf)**
・新規サービス用のECSセキュリティグループ（SG）を作成する。
・既存のRDS用SGのIDを data で取得し、aws_security_group_rule を用いて、新規サービス用SGからの3306通信を許可するルールを「後付け」で追加する。
・ECSタスクのアウトバウンド通信を制御し、不要な外部通信を制限すること。
・ECS FargateがECRからイメージをpullできるよう、Secret Manager（Interface型）、ECR API（Interface型）およびECR DKR（Interface型）のVPC Endpointを `network.tf` 内に追加すること。`shared_platform` 側のVPC Endpoint（S3・CloudWatch Logs）はそのまま共用できるため追加不要。

**課題3：パスベースルーティング (alb.tf)**
・既存の共有ALBに、パス /api/v2/* を受け持つリスナールールを追加する。
・リスナールールの優先度（Priority）は variable で管理し、既存サービスと重ならないようにする。
・HTTPSリスナー（443）を追加し、HTTPからHTTPSへのリダイレクト設定を行うこと。
・ACM証明書はDNS検証を用いて発行すること。なお、DNS検証レコードの実際の登録は省略してよい。`aws_acm_certificate` と `aws_acm_certificate_validation` の定義および `lifecycle { create_before_destroy = true }` の設定まで書けば合格とする。

**課題4：疎結合なシークレット管理 (secrets.tf)**
・AWS Secrets Managerを作成し、DBパスワードなどを格納する。
・ECSのタスク定義内では、直接値を書かず、Secrets ManagerのARNを valueFrom で参照する。

**課題5：ECS Fargateの構築 (ecs.tf)**
・ECSクラスター、タスク定義、サービスを構築する。
・タスク定義には ignore_changes = [cpu, memory] を設定し、運用の柔軟性を持たせる。
・コンテナ定義は .json.tftpl ファイルを templatefile 関数で読み込む形式にする。
・CloudWatch Logs へのログ出力設定（awslogsドライバ）を行うこと。
・サービスの desired_count は2以上とし、可用性を確保すること。
・Application Auto Scaling を用いて、CPU使用率またはALBリクエスト数に応じたスケーリングを設定すること。
・CloudWatch Alarm（CPU使用率70%超過）を `ecs.tf` 内に定義すること。
・マイグレーション専用のタスク定義（`aws_ecs_task_definition`）を通常のアプリ用タスク定義とは別に定義すること。
　- コンテナ起動コマンドは `php artisan migrate --force` とする。
　- サービスとして常駐させず、単発実行（run-task）を前提とした設計にする。
　- シーディング（初期データ投入）はマイグレーションとは分離し、初回のみ手動で `aws ecs run-task` を使って別途実行すること。

**課題6：CI/CD パイプライン (.github/workflows/deploy.yml)**
・GitHub Actions（OIDC）を使用してAWSに認証する。
・workflow_dispatch でデプロイ環境を選択可能にする。
・ビルドしたイメージに latest と ${github.sha} の両方のタグを付与してECRにプッシュする。
・Terraform実行前に fmt / validate / plan を実行するステップを含めること。
・**ECSサービスの更新前に、マイグレーション専用タスクを `aws ecs run-task` で単発実行し、完了を待ってからデプロイを進めること。** タスク内では `php artisan migrate --force` を実行する。マイグレーション失敗時はデプロイを中断すること。シーディング（`db:seed`）は初回のみ手動で実行すること。
・デプロイ後にヘルスチェックエンドポイントへの疎通確認を自動実行すること。
・ECRリポジトリは `resource_iam.tf` 内に `aws_ecr_repository` として定義し、リポジトリURIを `outputs.tf` から出力すること。

**ディレクトリ構成**
```
my_new_service/
├── provider.tf      # 環境ごとの共通タグ・バックエンド設定
├── variables.tf     # パラメータ定義
├── data.tf          # 【課題1】既存基盤の検索定義
├── network.tf       # 【課題2】新規SG・既存SGへのルール追加・ECR用及びSecret Manager用VPC Endpoint追加
├── alb.tf           # 【課題3】共有ALBへのパスベースルーティング設定
├── secrets.tf       # 【課題4】Secrets Managerの定義
├── ecs.tf           # 【課題5】ECSクラスター・サービス・タスク定義
├── resource_iam.tf  # 【課題6】各種実行ロールとGitHub連携設定・ECRリポジトリ定義
├── outputs.tf       # デプロイに必要な情報の出力（ECRリポジトリURIを含む）
└── container_def.json.tftpl  # 【課題5】ECSコンテナ定義テンプレート

env/
└── dev/
    ├── terraform.tfvars    # 開発環境用変数値
    └── terraform.tfbackend # S3バックエンド設定

.github/
└── workflows/
    └── deploy.yml          # 【課題6】CI/CDパイプライン

Dockerfile       # 【第２部】コンテナイメージ定義
.dockerignore    # 【第２部】イメージに含めないファイルの除外設定
Makefile         # Terraformコマンド共通化
```

---

#### Laravelアプリケーション側の準備
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

#### 成果物（全27ファイル想定）

**第１部：shared_platform（8ファイル）**
・`shared_platform/main.tf`
・`shared_platform/vpc.tf`
・`shared_platform/security_groups.tf`
・`shared_platform/alb.tf`
・`shared_platform/network_ext.tf`
・`shared_platform/rds.tf`
・`shared_platform/legacy_app.tf`
・`shared_platform/outputs.tf`

**第２部：コンテナ関連（2ファイル）**
・`Dockerfile`
・`.dockerignore`

**第３部：Terraform 関連（10ファイル）**
・`my_new_service/provider.tf`
・`my_new_service/variables.tf`
・`my_new_service/data.tf`
・`my_new_service/network.tf`
・`my_new_service/alb.tf`
・`my_new_service/secrets.tf`
・`my_new_service/ecs.tf`
・`my_new_service/resource_iam.tf`
・`my_new_service/outputs.tf`
・`my_new_service/container_def.json.tftpl`

**Laravelアプリケーション関連（3ファイル）**
・`database/migrations/xxxx_xx_xx_create_products_table.php`
・`database/seeders/ProductSeeder.php`
・`routes/api.php`

**その他（4ファイル）**
・`env/dev/terraform.tfvars`（`variables.tf` で定義した変数の dev 環境用の値を記載する）
・`.github/workflows/deploy.yml`（課題6の成果物）
・`Makefile`（`my_new_service/` 配下の Terraform 操作を対象に、`terraform init -backend-config=../env/dev/terraform.tfbackend` / `plan` / `apply` / `destroy` を `make` コマンドで実行できるよう共通化する）
・`env/dev/terraform.tfbackend`（S3バックエンド設定。`bucket`・`key`・`region`・`dynamodb_table` を定義する。`key` は `env/dev/terraform.tfstate` とする）

---

### 練習環境のコスト最適化構成

本問題を練習環境（個人のAWSアカウント）で実施する場合、以下の構成でコストを月2,000円以内に抑えることができる。**本番環境では適用しないこと。**

#### 基本方針
- 作業時間中のみ `terraform apply` し、終了後は必ず `terraform destroy` を実行する
- legacy_web（EC2）はNAT Gatewayを使わない設計のため、必要なパッケージを焼き込んだカスタムAMIを事前作成して使用する
- ECRへのイメージプッシュはローカルから手動で行う

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

ECS FargateからECRへのイメージpullは、第３部で `my_new_service` 側に Secret Manager用及びECR用VPC Endpoint（ECR API・ECR DKR）を追加することで対応する。`shared_platform` のVPC Endpoint（S3・CloudWatch Logs）はそのまま共用できる。ECRへのイメージプッシュはローカルから手動で実行する。

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
| ECS Fargate | 約100円 |
| VPC Endpoint × 2（shared_platform側） | 約60円 |
| VPC Endpoint × 3（my_new_service側・Secret Manager、ECR用） | 約40円 |
| EC2 t3.micro | 約20円 |
| **合計** | **約900円** |

---

### 完了条件（疎通確認仕様）

本プロジェクトにおけるインフラ構築の完了は、ALB経由で以下の応答が得られることをもって定義する。

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