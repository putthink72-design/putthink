import Foundation

enum LegalCopy {
    private static var isKorean: Bool {
        Locale.current.language.languageCode?.identifier == "ko"
    }

    private static var isJapanese: Bool {
        Locale.current.language.languageCode?.identifier == "ja"
    }

    static var privacyPolicy: String {
        if isKorean { return privacyKO }
        if isJapanese { return privacyJA }
        return privacyEN
    }

    static var eula: String {
        if isKorean { return eulaKO }
        if isJapanese { return eulaJA }
        return eulaEN
    }

    static var cancelGuide: String {
        if isKorean { return cancelKO }
        if isJapanese { return cancelJA }
        return cancelEN
    }

    private static let privacyEN = """
    ScanPar Privacy Policy
    Last updated: 4 September 2026

    ScanPar is a putting-guidance app. It uses your iPhone camera and LiDAR to scan the green between your golf ball and the hole, then estimates break and speed on this device.

    1. What we process
    • Camera and LiDAR depth/mesh: to reconstruct the putting surface between ball and hole and to show live aiming overlays. Frames are used for that session’s scan and guidance. We do not upload video, photos, or LiDAR meshes to our servers.
    • On-device scan files: height maps and related diagnostics may be stored locally so this round’s guidance can be computed. They stay on your iPhone unless you copy them off the device yourself.
    • App settings: language preference and similar options are stored in on-device settings (UserDefaults).
    • Apple subscriptions: if you subscribe, Apple processes the purchase through your Apple ID. We do not receive your full payment-card number.

    2. Accounts and tracking
    ScanPar does not create a user account. We do not use third-party advertising, analytics, or tracking SDKs, and we do not track you across other companies’ apps or websites.

    3. Permissions
    Camera access is required to scan the green between the ball and the hole, lock those two points, and build the putting height map with LiDAR. If you deny camera access, scanning cannot run. You can change this later in iOS Settings → Privacy & Security → Camera.

    4. Children
    ScanPar is not directed at children under 13.

    5. Your choices
    • Delete locally stored scans by deleting the app, or by clearing the app’s data.
    • Change language in ScanPar Settings.
    • Manage or cancel a subscription in your Apple ID subscription settings (deleting the app does not cancel billing).

    6. Contact
    For privacy questions, use the developer contact shown on the ScanPar product page on the App Store.
    """

    private static let privacyKO = """
    ScanPar 개인정보 처리방침
    최종 업데이트: 2026년 9월 4일

    ScanPar는 퍼팅 가이드 앱입니다. iPhone 카메라와 LiDAR로 볼과 홀 사이 그린을 스캔한 뒤, 이 기기에서 휘어짐과 스피드를 추정합니다.

    1. 처리하는 정보
    • 카메라 및 LiDAR 깊이/메시: 볼과 홀 사이 퍼팅 면을 재구성하고 조준 오버레이를 표시하기 위해 사용합니다. 해당 라운드 스캔·가이드에만 쓰이며, 영상·사진·LiDAR 메시를 당사 서버로 올리지 않습니다.
    • 기기 안 스캔 파일: 높이맵 등 진단 데이터가 이 라운드 계산을 위해 기기에 저장될 수 있습니다. 사용자가 직접 복사하지 않는 한 iPhone에만 남습니다.
    • 앱 설정: 언어 등 설정은 기기의 UserDefaults에 저장됩니다.
    • Apple 구독: 구독 결제는 Apple ID를 통해 Apple이 처리합니다. 카드 번호 전체를 당사가 받지 않습니다.

    2. 계정 및 추적
    ScanPar는 회원 계정을 만들지 않습니다. 제3자 광고·분석·추적 SDK를 쓰지 않으며, 다른 회사 앱·웹사이트를 가로질러 사용자를 추적하지 않습니다.

    3. 권한
    볼과 홀 사이 그린을 스캔하고 두 지점을 지정하며 LiDAR로 퍼팅 높이맵을 만들기 위해 카메라가 필요합니다. 카메라 접근을 거부하면 스캔을 할 수 없습니다. 나중에 iOS 설정 → 개인정보 보호 및 보안 → 카메라에서 변경할 수 있습니다.

    4. 아동
    ScanPar는 13세 미만 아동을 대상으로 하지 않습니다.

    5. 선택 권한
    • 앱을 삭제하거나 앱 데이터를 지우면 로컬 스캔이 삭제됩니다.
    • 언어는 ScanPar 설정에서 바꿀 수 있습니다.
    • 구독 해지·관리는 Apple ID 구독 설정에서 합니다. 앱 삭제만으로는 결제가 멈추지 않습니다.

    6. 문의
    개인정보 관련 문의는 App Store ScanPar 제품 페이지의 개발자 연락처를 이용해 주세요.
    """

    private static let privacyJA = """
    ScanPar プライバシーポリシー
    最終更新: 2026年9月4日

    ScanParはパッティング案内アプリです。iPhoneのカメラとLiDARでボールとホールの間のグリーンをスキャンし、この端末上で曲がりとスピードを推定します。

    1. 取り扱う情報
    • カメラおよびLiDARの深度/メッシュ: ボールとホールの間のパッティング面を再構成し、照準オーバーレイを表示するために使います。そのラウンドのスキャンと案内にのみ使用し、映像・写真・LiDARメッシュを当社サーバーへアップロードしません。
    • 端末内スキャンファイル: ハイトマップ等の診断データが、そのラウンドの計算のため端末に保存されることがあります。ご自身でコピーしない限りiPhone内に留まります。
    • アプリ設定: 言語などの設定は端末のUserDefaultsに保存されます。
    • Appleサブスクリプション: 購入はApple ID経由でAppleが処理します。カード番号全体は当社に届きません。

    2. アカウントとトラッキング
    ScanParはユーザーアカウントを作りません。第三者の広告・分析・トラッキングSDKは使わず、他社アプリやウェブサイトを横断して追跡しません。

    3. 許可
    ボールとホールの間のグリーンをスキャンし、2点を指定し、LiDARでパッティング用ハイトマップを作るためにカメラが必要です。カメラを拒否するとスキャンできません。後からiOS設定 → プライバシーとセキュリティ → カメラで変更できます。

    4. 子ども
    ScanParは13歳未満の子どもを対象にしていません。

    5. お客様の選択
    • アプリを削除するかデータを消すと、端末内スキャンは削除されます。
    • 言語はScanParの設定で変更できます。
    • 定期購入の管理・解約はApple IDのサブスクリプション設定で行います。アプリを消しただけでは課金は止まりません。

    6. お問い合わせ
    プライバシーに関するご質問は、App StoreのScanPar製品ページに掲載の開発者連絡先をご利用ください。
    """

    private static let eulaEN = """
    ScanPar End User License Agreement (EULA)
    Last updated: 4 September 2026

    This EULA is a license between you and the ScanPar developer (“Licensor”), not Apple. Apple is not a party to this EULA and is not responsible for ScanPar or its content. Apple is a third-party beneficiary of this EULA and may enforce it against you.

    1. License
    Licensor grants you a personal, non-exclusive, non-transferable, revocable license to use ScanPar on Apple-branded devices you own or control, as permitted by the App Store Terms of Use.

    2. ScanPar Pro subscription
    Putting scans and aim/speed guidance are provided as ScanPar Pro, an auto-renewable subscription sold through Apple In-App Purchase:
    • 1 month — US$9.99
    • 3 months — US$24.99
    • 6 months — US$44.99
    • 1 year — US$74.99
    Prices are in US dollars for the US storefront and may differ by country or region. Payment is charged to your Apple ID. The subscription renews automatically unless you cancel at least 24 hours before the end of the current period. Your account is charged for renewal within 24 hours before the period ends, at the then-current price.

    New subscribers who have not used an introductory offer in this subscription group may receive a 3-day free trial on their first eligible purchase. After the trial, the selected plan’s regular price applies unless you cancel in time. Apple determines trial eligibility (typically once per Apple ID per subscription group). Reinstalling the app does not reset eligibility.

    3. What the subscription includes
    While active, ScanPar Pro unlocks green scanning between ball and hole and on-device putting path / speed corridor guidance. Guidance is an estimate based on a LiDAR scan. It is not a guarantee of hole-outs, tournament results, or professional instruction.

    4. Device requirements
    Scanning needs an iPhone with LiDAR and camera permission. ScanPar may not function on devices without LiDAR scene reconstruction.

    5. Restrictions
    You may not reverse engineer, rent, or resell the app, or use it for unlawful purposes.

    6. Disclaimer
    ScanPar is provided “as is.” To the maximum extent permitted by law, Licensor disclaims warranties of merchantability, fitness for a particular purpose, and non-infringement. Outdoor lighting, grain, green speed, and scan quality affect results.

    7. Liability
    To the maximum extent permitted by law, Licensor is not liable for indirect or consequential damages, lost bets, or tournament losses arising from use of the guidance.

    8. Termination
    This license ends if you breach it or delete the app. Subscription billing is controlled by Apple until you cancel in Apple ID settings.

    9. Apple’s standard EULA
    Where required, Apple’s Licensed Application End User License Agreement also applies: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
    """

    private static let eulaKO = """
    ScanPar 이용약관 (EULA)
    최종 업데이트: 2026년 9월 4일

    본 약관은 사용자와 ScanPar 개발자(이하 “라이선서”) 사이의 라이선스이며 Apple의 약관이 아닙니다. Apple은 본 약관의 당사자가 아니며 ScanPar 또는 그 콘텐츠에 대해 책임지지 않습니다. Apple은 본 약관의 제3자 수익자로서 사용자에게 약관을 집행할 수 있습니다.

    1. 라이선스
    라이선서는 App Store 이용 약관이 허용하는 범위에서, 사용자가 소유하거나 관리하는 Apple 기기에서 ScanPar를 사용할 개인적·비독점·양도 불가·취소 가능한 라이선스를 부여합니다.

    2. ScanPar Pro 구독
    그린 스캔과 조준·스피드 가이드는 Apple 인앱 결제로 판매되는 자동 갱신 구독 ScanPar Pro로 제공됩니다.
    • 1개월 — US$9.99
    • 3개월 — US$24.99
    • 6개월 — US$44.99
    • 1년 — US$74.99
    표시 가격은 미국 스토어 기준 달러이며 국가·지역에 따라 다를 수 있습니다. 결제는 Apple ID로 청구됩니다. 현재 기간이 끝나기 최소 24시간 전에 해지하지 않으면 구독은 자동 갱신됩니다. 갱신 요금은 기간 종료 전 24시간 이내에 당시 가격으로 청구됩니다.

    이 구독 그룹에서 소개 혜택을 쓴 적이 없는 신규 구독자는, 첫 해당 구매에 한해 3일 무료 체험을 받을 수 있습니다. 체험이 끝나면 선택한 플랜의 정가가 적용됩니다. 체험 자격은 Apple이 판단하며(보통 Apple ID당 구독 그룹당 1회), 앱을 다시 설치해도 초기화되지 않습니다.

    3. 구독에 포함되는 내용
    구독이 유효한 동안 ScanPar Pro는 볼과 홀 사이 그린 스캔과 기기 안 퍼팅 경로·스피드 코리도어 가이드를 엽니다. 가이드는 LiDAR 스캔에 기반한 추정이며, 홀인·대회 성적·레슨을 보장하지 않습니다.

    4. 기기 요구 사항
    스캔에는 LiDAR가 있는 iPhone과 카메라 권한이 필요합니다. LiDAR 장면 재구성이 없는 기기에서는 동작하지 않을 수 있습니다.

    5. 제한
    앱을 리버스 엔지니어링하거나 대여·재판매하거나 불법 목적에 사용할 수 없습니다.

    6. 면책
    ScanPar는 “있는 그대로” 제공됩니다. 법이 허용하는 한 상품성, 특정 목적 적합성, 비침해 보증은 배제됩니다. 조명, 잔디결, 그린 스피드, 스캔 품질이 결과에 영향을 줍니다.

    7. 책임
    법이 허용하는 한, 가이드 사용으로 인한 간접 손해, 베팅 손실, 대회 손실에 대해 라이선서는 책임지지 않습니다.

    8. 종료
    약관을 위반하거나 앱을 삭제하면 라이선스는 종료됩니다. 구독 결제는 Apple ID 설정에서 해지할 때까지 Apple이 관리합니다.

    9. Apple 표준 EULA
    필요한 경우 Apple 표준 라이선스 응용 프로그램 EULA도 적용됩니다.
    https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
    """

    private static let eulaJA = """
    ScanPar エンドユーザー使用許諾契約 (EULA)
    最終更新: 2026年9月4日

    本EULAはお客様とScanPar開発者（「許諾者」）とのライセンスであり、Appleとの契約ではありません。Appleは本EULAの当事者ではなく、ScanParやその内容について責任を負いません。Appleは本EULAの第三者受益者であり、お客様に対してこれを執行できます。

    1. ライセンス
    許諾者は、App Store利用規約が認める範囲で、お客様が所有または管理するApple製デバイス上でScanParを使用する、個人的・非独占・譲渡不可・取消可能なライセンスを付与します。

    2. ScanPar Proサブスクリプション
    グリーンのスキャンと照準・スピード案内は、Appleアプリ内課金の自動更新サブスクリプション「ScanPar Pro」として提供されます。
    • 1か月 — US$9.99
    • 3か月 — US$24.99
    • 6か月 — US$44.99
    • 1年 — US$74.99
    表示価格は米国ストアの米ドルであり、国・地域により異なる場合があります。支払いはApple IDに請求されます。現在の期間終了の少なくとも24時間前に解約しない限り自動更新されます。更新料金は期間終了前24時間以内に、その時点の価格で請求されます。

    このサブスクリプショングループで導入オファーを使ったことがない新規購読者は、最初の対象購入に限り3日間の無料トライアルを受けられることがあります。トライアル後は選択したプランの通常価格が適用されます。資格はAppleが判断し（通常Apple IDあたりグループあたり1回）、アプリの再インストールではリセットされません。

    3. 含まれる内容
    有効期間中、ScanPar Proはボールとホールの間のグリーンスキャンと、端末上のパッティング経路・スピードコリドー案内を利用できます。案内はLiDARスキャンに基づく推定であり、カップインや競技成績、レッスンを保証しません。

    4. デバイス要件
    スキャンにはLiDAR搭載iPhoneとカメラ許可が必要です。LiDARシーン再構成のない端末では動作しない場合があります。

    5. 制限
    リバースエンジニアリング、貸与、転売、違法目的での使用はできません。

    6. 免責
    ScanParは現状有姿で提供されます。法律が許す限り、商品性・特定目的適合性・非侵害の保証は否認されます。照明、芝目、グリーンスピード、スキャン品質が結果に影響します。

    7. 責任
    法律が許す限り、案内の利用による間接損害、賭けの損失、競技の損失について許諾者は責任を負いません。

    8. 終了
    本契約に違反するかアプリを削除するとライセンスは終了します。定期購入の課金は、Apple ID設定で解約するまでAppleが管理します。

    9. Apple標準EULA
    必要な場合、Appleの標準Licensed Application EULAも適用されます。
    https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
    """

    private static let cancelEN = """
    How to cancel

    ScanPar Pro auto-renews until you cancel. Deleting the app does not stop billing.

    On iPhone:
    1. Open Settings.
    2. Tap your name, then Subscriptions.
    3. Tap ScanPar Pro (or ScanPar).
    4. Tap Cancel Subscription and confirm.

    You can also use Manage Subscription in this screen, which opens Apple’s subscription sheet.

    Cancel at least 24 hours before the current period (or free trial) ends to avoid the next charge. If you started a 3-day trial, cancel before the trial ends or the selected plan’s price is billed.

    Restore Purchases re-downloads an existing Apple ID subscription on this or another device. It does not create a new charge.
    """

    private static let cancelKO = """
    구독 해지 방법

    ScanPar Pro는 해지하기 전까지 자동 갱신됩니다. 앱만 삭제해도 결제는 멈추지 않습니다.

    iPhone에서:
    1. 설정 앱을 엽니다.
    2. 이름을 탭한 뒤 구독을 엽니다.
    3. ScanPar Pro(또는 ScanPar)를 선택합니다.
    4. 구독 취소를 탭하고 확인합니다.

    이 화면의 구독 관리를 누르면 Apple 구독 시트가 열립니다.

    다음 결제를 막으려면 현재 기간(또는 무료 체험)이 끝나기 최소 24시간 전에 해지하세요. 3일 체험 중이라면 체험이 끝나기 전에 해지해야 선택한 플랜 요금이 청구되지 않습니다.

    구독 복원은 같은 Apple ID의 기존 구독을 이 기기(또는 다른 기기)에 다시 연결합니다. 새 결제가 발생하지 않습니다.
    """

    private static let cancelJA = """
    解約方法

    ScanPar Proは解約するまで自動更新されます。アプリを削除しただけでは課金は止まりません。

    iPhoneの場合:
    1. 設定を開きます。
    2. 自分の名前 → サブスクリプション を開きます。
    3. ScanPar Pro（またはScanPar）を選びます。
    4. サブスクリプションをキャンセル をタップして確認します。

    この画面の「サブスクリプションを管理」からもAppleの管理画面を開けます。

    次の請求を避けるには、現在の期間（または無料トライアル）の終了少なくとも24時間前に解約してください。3日間トライアル中なら、終了前に解約しないと選択したプランの料金が請求されます。

    購入の復元は、同じApple IDの既存サブスクリプションをこの端末（または別の端末）に再接続します。新規の課金は発生しません。
    """

    static func blocks(from text: String) -> [LegalBlock] {
        var blocks: [LegalBlock] = []
        var bullets: [String] = []
        var steps: [String] = []
        var sawTitle = false

        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullets(bullets))
            bullets = []
        }

        func flushSteps() {
            guard !steps.isEmpty else { return }
            blocks.append(.steps(steps))
            steps = []
        }

        func flushLists() {
            flushBullets()
            flushSteps()
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushLists()
                continue
            }

            if !sawTitle {
                sawTitle = true
                continue
            }

            if line.hasPrefix("Last updated")
                || line.hasPrefix("최종 업데이트")
                || line.hasPrefix("最終更新") {
                flushLists()
                blocks.append(.updated(line))
                continue
            }

            if line.hasPrefix("•") {
                flushSteps()
                bullets.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            if let heading = Self.sectionHeading(line) {
                flushLists()
                blocks.append(.heading(heading))
                continue
            }

            if let step = Self.numberedStep(line) {
                flushBullets()
                steps.append(step)
                continue
            }

            if line.hasSuffix(":"), line.count <= 28 {
                flushLists()
                blocks.append(.kicker(String(line.dropLast())))
                continue
            }

            flushLists()
            if let url = Self.isolatedURL(line) {
                blocks.append(.link(url))
            } else if let split = Self.paragraphWithTrailingURL(line) {
                blocks.append(.paragraph(split.text))
                blocks.append(.link(split.url))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        flushLists()
        return blocks
    }

    private static func numberedRemainder(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: "."),
              line.startIndex < dot,
              line[line.startIndex..<dot].allSatisfy(\.isNumber)
        else { return nil }
        let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    private static func sectionHeading(_ line: String) -> String? {
        guard let rest = numberedRemainder(line) else { return nil }
        let endsLikeSentence =
            rest.hasSuffix(".") || rest.hasSuffix("。") || rest.hasSuffix("다.")
        guard !endsLikeSentence, rest.count <= 48 else { return nil }
        return rest
    }

    private static func numberedStep(_ line: String) -> String? {
        guard let rest = numberedRemainder(line), sectionHeading(line) == nil else { return nil }
        return rest
    }

    private static func isolatedURL(_ line: String) -> URL? {
        guard line.hasPrefix("http"), let url = URL(string: line) else { return nil }
        return url
    }

    private static func paragraphWithTrailingURL(_ line: String) -> (text: String, url: URL)? {
        guard let range = line.range(of: "https://", options: .backwards) else { return nil }
        let urlString = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString) else { return nil }
        let text = String(line[..<range.lowerBound])
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
        return (text, url)
    }
}

enum LegalBlock {
    case updated(String)
    case heading(String)
    case kicker(String)
    case paragraph(String)
    case bullets([String])
    case steps([String])
    case link(URL)
}
