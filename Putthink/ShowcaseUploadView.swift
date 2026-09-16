import SwiftUI

/// Control Center screen recording → compress → meta → Supabase `putt-showcase` upload.
struct ShowcaseUploadView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var auth: AuthSessionStore
    @EnvironmentObject private var devMode: DevModeStore
    @EnvironmentObject private var nicknameStore: NicknameStore
    @EnvironmentObject private var invite: InviteStore
    @EnvironmentObject private var language: AppLanguageStore
    @EnvironmentObject private var freeRuns: FreeRunsStore
    @StateObject private var model = ShowcaseUploadModel()
    @State private var showVideoPicker = false
    @State private var showInviteNudge = false
    @FocusState private var focusedMetaField: MetaField?

    private enum MetaField: Hashable {
        case nickname, caption, club, course
    }

    private var hasPro: Bool { subscriptions.hasProAccess(devMode: devMode) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    instructionCard
                    if !hasPro {
                        SettingsCard(title: L10n.showcaseUploadGateTitle, footnote: nil) {
                            Text(L10n.showcaseUploadNeedPro)
                                .font(.system(size: 13))
                                .foregroundStyle(OSDPalette.textSecondary)
                        }
                    } else {
                        pickerCard
                        metaCard
                        uploadSection
                    }
                    if let status = model.statusMessage, !status.isEmpty,
                       !model.isPreparing, !model.isUploading {
                        Text(status)
                            .font(.system(size: 13))
                            .foregroundStyle(model.didSucceed ? OSDPalette.status : OSDPalette.accent)
                    }
                }
                .padding(16)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded { focusedMetaField = nil }
                )
            }
            .scrollDismissesKeyboard(.interactively)
            .background(settingsBackground)
            .navigationTitle(L10n.showcaseUploadTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.settingsDone, action: dismiss.callAsFunction)
                        .foregroundStyle(OSDPalette.accent)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.settingsDone) { focusedMetaField = nil }
                        .foregroundStyle(OSDPalette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showVideoPicker) {
            SingleVideoLibraryPicker { url in
                Task { await model.loadVideo(from: url) }
            }
        }
        .sheet(isPresented: $invite.showInviteShare) {
            if invite.inviteURL != nil {
                ActivityShareSheet(items: [invite.shareMessage(for: language.locale)]) {
                    invite.showInviteShare = false
                    dismiss()
                }
            }
        }
        .alert(L10n.inviteNudgeTitle, isPresented: $showInviteNudge) {
            Button(L10n.inviteShareCTA) {
                Task {
                    await invite.ensureCodeAndShare(auth: auth)
                    if !invite.showInviteShare {
                        dismiss()
                    }
                }
            }
            Button(L10n.inviteNudgeSkip, role: .cancel) {
                dismiss()
            }
        } message: {
            Text(L10n.inviteNudgeBody)
        }
        .onAppear {
            if model.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.nickname = nicknameStore.nickname
            }
        }
    }

    private var instructionCard: some View {
        SettingsCard(title: L10n.showcaseUploadHowTitle, footnote: nil) {
            Text(L10n.showcaseUploadHowBody)
                .font(.system(size: 13))
                .foregroundStyle(OSDPalette.textSecondary)
                .lineSpacing(3)
        }
    }

    private var pickerCard: some View {
        SettingsCard(title: L10n.showcaseUploadPickTitle, footnote: L10n.showcaseUploadPickFooter) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    guard !model.isPreparing, !model.isUploading else { return }
                    showVideoPicker = true
                } label: {
                    Text(model.localVideoURL == nil ? L10n.showcaseUploadPickCTA : L10n.showcaseUploadPickReplace)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OSDPalette.accentInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(OSDPalette.accent, in: Capsule())
                }
                .disabled(model.isPreparing || model.isUploading)

                if model.isPreparing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.showcaseUploadCompressingPct(Int((model.prepareProgress * 100).rounded())))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OSDPalette.textSecondary)
                        ProgressView(value: model.prepareProgress)
                            .tint(OSDPalette.accent)
                    }
                } else if model.localVideoURL != nil {
                    Text(model.statusMessage ?? L10n.showcaseUploadReady)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OSDPalette.status)
                }
            }
        }
    }

    private var metaCard: some View {
        SettingsCard(title: L10n.showcaseUploadMetaTitle, footnote: L10n.nicknameFooter) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(L10n.showcaseUploadCategory, selection: $model.category) {
                    ForEach(ShowcaseCategory.allCases) { cat in
                        Text(cat.title).tag(cat)
                    }
                }
                .pickerStyle(.menu)
                .tint(OSDPalette.accent)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.showcaseUploadNickname)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OSDPalette.textTertiary)
                    HStack(spacing: 8) {
                        TextField(L10n.showcaseUploadNickname, text: $model.nickname)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .padding(12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(OSDPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .focused($focusedMetaField, equals: .nickname)
                            .submitLabel(.done)
                            .onSubmit { focusedMetaField = nil }

                        Button {
                            focusedMetaField = nil
                            nicknameStore.regenerate()
                            model.nickname = nicknameStore.nickname
                        } label: {
                            Image(systemName: "die.face.5.fill")
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(OSDPalette.accentInk)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(OSDPalette.accent)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(OSDPalette.accentInk.opacity(0.25), lineWidth: 1)
                                )
                        }
                        .accessibilityLabel(L10n.nicknameRegenerate)
                    }
                }

                field(L10n.showcaseUploadCaption, text: $model.caption, field: .caption)
                field(L10n.showcaseUploadClub, text: $model.clubName, field: .club)
                field(L10n.showcaseUploadCourse, text: $model.courseName, field: .course)

                Stepper(
                    value: $model.holeNumber,
                    in: 1...18
                ) {
                    Text("\(L10n.showcaseUploadHole) \(model.holeNumber)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OSDPalette.textPrimary)
                }

                if let msg = nicknameStore.statusMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(OSDPalette.accent)
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, field: MetaField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OSDPalette.textTertiary)
            TextField(title, text: text)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(OSDPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .focused($focusedMetaField, equals: field)
                .submitLabel(.done)
                .onSubmit { focusedMetaField = nil }
        }
    }

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            OSDPrimaryButton(
                title: model.isUploading
                    ? L10n.showcaseUploadUploadingPct(Int((model.uploadProgress * 100).rounded()))
                    : L10n.showcaseUploadSubmit,
                enabled: model.canSubmit
            ) {
                Task { await submit() }
            }

            if model.isUploading {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.showcaseUploadUploadingPct(Int((model.uploadProgress * 100).rounded())))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OSDPalette.textSecondary)
                    ProgressView(value: model.uploadProgress)
                        .tint(OSDPalette.accent)
                }
            }
        }
    }

    private func submit() async {
        let nick = model.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NicknameProfanityFilter.isAllowed(nick) else {
            model.statusMessage = L10n.nicknameRejected
            return
        }
        if nick != nicknameStore.nickname {
            guard nicknameStore.setCustom(nick) else {
                model.statusMessage = nicknameStore.statusMessage ?? L10n.nicknameRejected
                return
            }
        }
        do {
            try await auth.ensureSupabaseSessionForUpload()
            guard let token = auth.supabaseAccessToken, let uid = auth.userID else {
                model.statusMessage = L10n.showcaseUploadNeedSignIn
                return
            }
            await freeRuns.syncClaimWithServer(auth: auth)
            await ShowcaseSupabaseUploader.syncDisplayNickname(
                userID: uid,
                accessToken: token,
                nickname: nicknameStore.nickname,
                onCollision: {
                    let next = nicknameStore.retryDigitsAfterCollision()
                    model.nickname = next
                    return next
                }
            )
            await model.upload(accessToken: token, userID: uid)
            if model.didSucceed {
                showInviteNudge = true
            }
        } catch {
            model.statusMessage = error.localizedDescription
        }
    }

    private var settingsBackground: some View {
        ZStack {
            Color(red: 8 / 255, green: 12 / 255, blue: 10 / 255)
            OSDPalette.glassStrong
        }
        .ignoresSafeArea()
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
