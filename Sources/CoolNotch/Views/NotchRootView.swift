import SwiftUI
import UniformTypeIdentifiers

/// Содержимое чёлки. Саму форму, тень, стекло и эффекты рисует Core Animation (NotchChrome),
/// поэтому здесь нет фона и обрезки — SwiftUI не пересчитывается на каждом кадре анимации.
struct NotchRootView: View {
    var body: some View {
        VStack(spacing: 0) {
            NotchContent()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

private struct NotchContent: View {
    @Environment(NotchViewModel.self) var vm
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        let size = vm.shapeSize
        let simple = reduceMotion || vm.lowPower

        ZStack(alignment: .top) {
            if vm.isDropTargeted {
                Color.white.opacity(0.08)
                    .transition(.opacity)
            }
            content(simple: simple)
        }
        .frame(width: size.width + vm.topRadius * 2, height: size.height, alignment: .top)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: dropBinding) { providers in
            vm.handleDrop(providers)
        }
        .animation(simple ? Theme.reduced : Theme.content, value: vm.presentation)
        .animation(Theme.micro, value: vm.isDropTargeted)
    }

    @ViewBuilder
    private func content(simple: Bool) -> some View {
        switch vm.presentation {
        case .open:
            ExpandedNotchView()
                .frame(width: vm.openSize.width, height: vm.openSize.height, alignment: .top)
                .transition(
                    AsymmetricTransition(
                        insertion: RevealTransition(scale: 0.96, offset: CGSize(width: 0, height: -8))
                            .animation(simple ? Theme.reduced : .spring(response: 0.42, dampingFraction: 0.9).delay(0.07)),
                        removal: RevealTransition(scale: 0.97, offset: CGSize(width: 0, height: -4))
                            .animation(.easeOut(duration: 0.12))
                    )
                )
        case .banner(let banner):
            BannerView(banner: banner)
                .frame(width: vm.bannerSize.width, height: vm.bannerSize.height, alignment: .top)
                .id(banner.id)
                .transition(
                    AsymmetricTransition(
                        insertion: RevealTransition(scale: 0.95, offset: CGSize(width: 0, height: -6))
                            .animation(simple ? Theme.reduced : .spring(response: 0.42, dampingFraction: 0.9).delay(0.08)),
                        removal: RevealTransition(scale: 0.97, offset: CGSize(width: 0, height: -4))
                            .animation(.easeOut(duration: 0.12))
                    )
                )
        case .closed:
            ClosedNotchView()
                .frame(width: vm.closedSize.width, height: vm.closedSize.height, alignment: .top)
                .transition(OpacityTransition().animation(.easeInOut(duration: 0.18)))
        }
    }

    private var dropBinding: Binding<Bool> {
        Binding(
            get: { vm.isDropTargeted },
            set: { newValue in
                if vm.isDropTargeted != newValue { vm.isDropTargeted = newValue }
            }
        )
    }
}
