import StoreKit
import SwiftUI

struct AppSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var language: AppLanguageStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var selectedProductID: String?
    @State private var showLanguageReloadAlert = false
    @State private var showCancelGuide = false
    @State private var legalKind: LegalKind?

    var body: some View {
        ZStack {
            settingsContent
            if let legalKind {
                LegalDocumentView(kind: legalKind) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        self.legalKind = nil
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(settingsBackground)
                .transition(.move(edge: .bottom))
                .zIndex(1)
                .ignoresSafeArea()
            }
        }
        .background(settingsBackground)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.28), value: legalKind?.id)
        .task {
            await subscriptions.refresh()
            if selectedProductID == nil {
                selectedProductID = subscriptions.products.first?.id
                    ?? DisplayPlan.fallbackPlans.first?.id
            }
        }
        .alert(L10n.settingsLanguageReloadTitle, isPresented: $showLanguageReloadAlert) {
            Button(L10n.settingsLanguageReloadLater, role: .cancel) {}
            Button(L10n.settingsLanguageReloadNow, role: .destructive) {
                exit(0)
            }
        } message: {
            Text(L10n.settingsLanguageReloadBody)
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    languageCard
                    subscriptionCard
                    legalCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(L10n.settingsTitle)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(OSDPalette.textPrimary)
            Spacer(minLength: 12)
            Button(L10n.settingsDone, action: dismiss.callAsFunction)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OSDPalette.accent)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var languageCard: some View {
        SettingsCard(title: L10n.settingsLanguage, footnote: L10n.settingsLanguageFooter) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(AppLanguageOption.allCases) { option in
                    languageChip(option)
                }
            }
        }
    }

    private func languageChip(_ option: AppLanguageOption) -> some View {
        let selected = language.option == option
        return Button {
            guard option != language.option else { return }
            language.select(option)
            showLanguageReloadAlert = true
        } label: {
            Text(option.settingsLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? OSDPalette.accentInk : OSDPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? OSDPalette.accent : OSDPalette.accentSoft, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        selected ? Color.clear : OSDPalette.glassBorder,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private var subscriptionCard: some View {
        SettingsCard(title: L10n.settingsSubscribe, footnote: nil) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.settingsSubscribeBody)
                    .font(.system(size: 12.5))
                    .foregroundStyle(OSDPalette.textSecondary)
                    .lineSpacing(3)

                if subscriptions.isSubscribed {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                        Text(L10n.settingsSubscribeActive)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OSDPalette.status)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(displayedPlans) { plan in
                        planTile(plan)
                    }
                }

                if displayedPlans.contains(where: \.showsTrial) {
                    Text(L10n.settingsTrialShort)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OSDPalette.status)
                        .lineSpacing(2)
                }

                if let message = subscriptions.statusMessage, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(OSDPalette.accent)
                }

                if !subscriptions.isSubscribed {
                    OSDPrimaryButton(
                        title: subscribeButtonTitle,
                        enabled: !subscriptions.isBusy && selectedProductID != nil
                    ) {
                        Task { await purchaseSelected() }
                    }
                }

                HStack(spacing: 0) {
                    Button(L10n.settingsRestore) {
                        Task { await subscriptions.restore() }
                    }
                    Spacer()
                    Button(L10n.settingsManage) {
                        Task { await subscriptions.manageSubscriptions() }
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OSDPalette.textSecondary)
                .disabled(subscriptions.isBusy)
                .padding(.top, 2)

                DisclosureGroup(isExpanded: $showCancelGuide) {
                    LegalFormattedBody(text: LegalCopy.cancelGuide)
                        .padding(.top, 10)
                } label: {
                    Text(L10n.settingsCancelTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OSDPalette.textPrimary)
                }
                .tint(OSDPalette.accent)

                Text(L10n.settingsSubscribeLegalFooter)
                    .font(.system(size: 11))
                    .foregroundStyle(OSDPalette.textTertiary)
                    .lineSpacing(2)
            }
        }
    }

    private func planTile(_ plan: DisplayPlan) -> some View {
        let selected = selectedProductID == plan.id
        return Button {
            selectedProductID = plan.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OSDPalette.textSecondary)
                Text(plan.price)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(OSDPalette.textPrimary)
                    .monospacedDigit()
                if let percent = plan.savingsPercent {
                    Text(L10n.planSavePercent(percent))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(OSDPalette.status)
                } else {
                    Text(L10n.planStandardRate)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OSDPalette.textTertiary)
                }
                if plan.showsTrial {
                    Text(L10n.planTrialChip)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OSDPalette.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? OSDPalette.accentSoft : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? OSDPalette.accent : OSDPalette.glassBorder, lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(subscriptions.isBusy)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var legalCard: some View {
        SettingsCard(title: L10n.settingsLegal, footnote: nil) {
            VStack(spacing: 0) {
                legalRow(L10n.settingsPrivacy) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        legalKind = .privacy
                    }
                }
                Rectangle()
                    .fill(OSDPalette.glassHair)
                    .frame(height: 1)
                    .padding(.vertical, 4)
                legalRow(L10n.settingsEULA) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        legalKind = .eula
                    }
                }
            }
        }
    }

    private func legalRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OSDPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OSDPalette.textTertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settingsBackground: some View {
        ZStack {
            Color(red: 8 / 255, green: 12 / 255, blue: 10 / 255)
            OSDPalette.glassStrong
        }
        .ignoresSafeArea()
    }

    private var displayedPlans: [DisplayPlan] {
        DisplayPlan.build(
            products: subscriptions.products,
            introEligible: subscriptions.introEligibleProductIDs
        )
    }

    private var selectedPlanShowsTrial: Bool {
        guard let id = selectedProductID else { return false }
        return displayedPlans.first(where: { $0.id == id })?.showsTrial == true
    }

    private var subscribeButtonTitle: String {
        selectedPlanShowsTrial ? L10n.settingsStartTrial : L10n.settingsSubscribeCTA
    }

    private func purchaseSelected() async {
        let plans = displayedPlans
        guard let id = selectedProductID,
              let plan = plans.first(where: { $0.id == id })
        else { return }
        if let product = plan.storeProduct ?? subscriptions.products.first(where: { $0.id == id }) {
            await subscriptions.purchase(product)
        } else {
            subscriptions.statusMessage = L10n.settingsStoreUnavailable
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(OSDPalette.accent)
            content()
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(OSDPalette.textTertiary)
                    .lineSpacing(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OSDPalette.glass, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(OSDPalette.glassBorder, lineWidth: 1)
        )
    }
}

private struct DisplayPlan: Identifiable {
    let id: String
    let title: String
    let price: String
    let months: Int
    let savingsPercent: Int?
    let showsTrial: Bool
    var storeProduct: Product?

    static func build(products: [Product], introEligible: Set<String>) -> [DisplayPlan] {
        if products.isEmpty {
            return fallbackPlans
        }
        let monthlyPrice = products.first(where: { $0.id == SubscriptionStore.productIDs[0] })?.price
        return products.map { product in
            let months = monthCount(for: product.id)
            return DisplayPlan(
                id: product.id,
                title: title(for: product.id),
                price: product.displayPrice,
                months: months,
                savingsPercent: savingsPercent(months: months, price: product.price, monthly: monthlyPrice),
                showsTrial: introEligible.contains(product.id),
                storeProduct: product
            )
        }
    }

    static var fallbackPlans: [DisplayPlan] {
        [
            DisplayPlan(
                id: SubscriptionStore.productIDs[0],
                title: L10n.planMonth,
                price: "$9.99",
                months: 1,
                savingsPercent: nil,
                showsTrial: true,
                storeProduct: nil
            ),
            DisplayPlan(
                id: SubscriptionStore.productIDs[1],
                title: L10n.planQuarter,
                price: "$24.99",
                months: 3,
                savingsPercent: 17,
                showsTrial: true,
                storeProduct: nil
            ),
            DisplayPlan(
                id: SubscriptionStore.productIDs[2],
                title: L10n.planSixMonth,
                price: "$44.99",
                months: 6,
                savingsPercent: 25,
                showsTrial: true,
                storeProduct: nil
            ),
            DisplayPlan(
                id: SubscriptionStore.productIDs[3],
                title: L10n.planYear,
                price: "$74.99",
                months: 12,
                savingsPercent: 37,
                showsTrial: true,
                storeProduct: nil
            ),
        ]
    }

    static func title(for productID: String) -> String {
        switch productID {
        case SubscriptionStore.productIDs[0]: return L10n.planMonth
        case SubscriptionStore.productIDs[1]: return L10n.planQuarter
        case SubscriptionStore.productIDs[2]: return L10n.planSixMonth
        case SubscriptionStore.productIDs[3]: return L10n.planYear
        default: return productID
        }
    }

    static func monthCount(for productID: String) -> Int {
        switch productID {
        case SubscriptionStore.productIDs[0]: return 1
        case SubscriptionStore.productIDs[1]: return 3
        case SubscriptionStore.productIDs[2]: return 6
        case SubscriptionStore.productIDs[3]: return 12
        default: return 1
        }
    }

    static func savingsPercent(months: Int, price: Decimal, monthly: Decimal?) -> Int? {
        guard months >= 3, let monthly, monthly > 0 else { return nil }
        let equivalent = monthly * Decimal(months)
        guard price < equivalent else { return nil }
        let percent = NSDecimalNumber(decimal: ((equivalent - price) / equivalent) * 100).doubleValue
        let rounded = Int(percent.rounded())
        return rounded > 0 ? rounded : nil
    }
}

enum LegalKind: String, Identifiable {
    case privacy
    case eula
    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return L10n.settingsPrivacy
        case .eula: return L10n.settingsEULA
        }
    }

    var bodyText: String {
        switch self {
        case .privacy: return LegalCopy.privacyPolicy
        case .eula: return LegalCopy.eula
        }
    }
}

struct LegalDocumentView: View {
    let kind: LegalKind
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(kind.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(OSDPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button(L10n.settingsDone, action: onClose)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OSDPalette.accent)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)

            ScrollView {
                LegalFormattedBody(text: kind.bodyText)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }
}

struct LegalFormattedBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(LegalCopy.blocks(from: text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: LegalBlock) -> some View {
        switch block {
        case .updated(let line):
            Text(line)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OSDPalette.textTertiary)
                .padding(.bottom, 16)

        case .heading(let title):
            Text(title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(OSDPalette.accent)
                .padding(.top, 22)
                .padding(.bottom, 8)

        case .kicker(let title):
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OSDPalette.textSecondary)
                .padding(.top, 14)
                .padding(.bottom, 8)

        case .paragraph(let body):
            Text(body)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(OSDPalette.textPrimary)
                .lineSpacing(5)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(OSDPalette.accent)
                            .frame(width: 5, height: 5)
                            .padding(.top, 8)
                        Text(item)
                            .font(.system(size: 15))
                            .foregroundStyle(OSDPalette.textPrimary)
                            .lineSpacing(4)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.bottom, 12)

        case .steps(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(OSDPalette.accentInk)
                            .frame(width: 20, height: 20)
                            .background(OSDPalette.accent, in: Circle())
                        Text(item)
                            .font(.system(size: 15))
                            .foregroundStyle(OSDPalette.textPrimary)
                            .lineSpacing(4)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.bottom, 12)

        case .link(let url):
            Link(destination: url) {
                Text(url.host ?? url.absoluteString)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OSDPalette.accent)
                    .underline()
                    .multilineTextAlignment(.leading)
            }
            .padding(.bottom, 12)
        }
    }
}

private extension AppLanguageOption {
    var settingsLabel: String {
        switch self {
        case .system: return L10n.settingsLanguageSystem
        case .en: return L10n.settingsLanguageEnglish
        case .ko: return L10n.settingsLanguageKorean
        case .ja: return L10n.settingsLanguageJapanese
        }
    }
}
