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
        let chromatic = vm.fxChromatic && !simple
        switch vm.presentation {
        case .open:
            ExpandedNotchView()
                .frame(width: vm.openSize.width, height: vm.openSize.height, alignment: .top)
                .transition(
                    AsymmetricTransition(
                        insertion: RevealTransition(blur: 0, scale: 0.93, offset: CGSize(width: 0, height: -14))
                            .animation(simple ? Theme.reduced : .spring(response: 0.5, dampingFraction: 0.72).delay(0.06)),
                        removal: RevealTransition(blur: 0, scale: 0.9, offset: CGSize(width: 0, height: -10))
                            .animation(.easeIn(duration: 0.14))
                    )
                )
        case .banner(let banner):
            BannerView(banner: banner)
                .frame(width: vm.bannerSize.width, height: vm.bannerSize.height, alignment: .top)
                .id(banner.id)
                .transition(
                    AsymmetricTransition(
                        insertion: RevealTransition(blur: simple ? 0 : 6, scale: 0.88, offset: CGSize(width: 0, height: -8), chromatic: chromatic)
                            .animation(simple ? Theme.reduced : .spring(response: 0.5, dampingFraction: 0.7).delay(0.08)),
                        removal: RevealTransition(blur: 0, scale: 0.9, offset: CGSize(width: 0, height: -6))
                            .animation(.easeIn(duration: 0.14))
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
