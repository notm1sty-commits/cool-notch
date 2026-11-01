import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    var body: some View {
        VStack(spacing: 0) {
            NotchContainer()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

private struct NotchContainer: View {
    @Environment(NotchViewModel.self) var vm
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        let motion = vm.motion
        let shape = NotchShape(topRadius: motion.shoulder, bottomRadius: motion.bottomRadius)
        let simple = reduceMotion || vm.lowPower
        let lifted = vm.presentation != .closed
        let glass = vm.isGlassActive

        ZStack(alignment: .top) {
            content(simple: simple)
        }
        .frame(width: motion.width, height: motion.height, alignment: .top)
        .padding(.horizontal, motion.shoulder)
        .background {
            NotchBackground(shape: shape, glass: glass, lifted: lifted)
        }
        .clipShape(shape)
        .overlay {
            if lifted {
                RimLight(shape: shape)
                    .opacity(glass ? 1 : 0.45)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if glass {
                // Аппаратный вырез остаётся чёрным поверх стекла.
                NotchShape(topRadius: 6, bottomRadius: 10)
                    .fill(Color.black)
                    .frame(width: vm.notchSize.width + 12, height: vm.notchSize.height)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if vm.fxEdgeGlow && !simple {
                EdgeGlow(shape: shape, trigger: vm.glowTrigger, green: vm.glowGreen)
            }
        }
        .background {
            if vm.fxChromatic && !simple && motion.aberration > 0.004 {
                ChromaticFringe(shape: shape, amount: motion.aberration)
            }
        }
        .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: lifted ? 26 : 0, y: lifted ? 12 : 0)
        .contentShape(shape)
        .onDrop(of: [.fileURL], isTargeted: dropBinding) { providers in
            vm.handleDrop(providers)
        }
        .animation(simple ? Theme.reduced : Theme.content, value: vm.presentation)
        .animation(Theme.content, value: glass)
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
                        insertion: RevealTransition(blur: simple ? 0 : 12, scale: 0.94, offset: CGSize(width: 0, height: -12), chromatic: chromatic)
                            .animation(simple ? Theme.reduced : Theme.content.delay(0.07)),
                        removal: OpacityTransition().animation(.easeOut(duration: 0.12))
                    )
                )
        case .banner(let banner):
            BannerView(banner: banner)
                .frame(width: vm.bannerSize.width, height: vm.bannerSize.height, alignment: .top)
                .id(banner.id)
                .transition(
                    AsymmetricTransition(
                        insertion: RevealTransition(blur: simple ? 0 : 8, scale: 0.9, offset: CGSize(width: 0, height: -6), chromatic: chromatic)
                            .animation(simple ? Theme.reduced : Theme.content.delay(0.08)),
                        removal: OpacityTransition().animation(.easeOut(duration: 0.12))
                    )
                )
        case .closed:
            ClosedNotchView()
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

/// Подложка чёлки: чёрная или стеклянная, с цветом обложки внутри.
private struct NotchBackground: View {
    @Environment(NotchViewModel.self) var vm
    var shape: NotchShape
    var glass: Bool
    var lifted: Bool

    var body: some View {
        ZStack {
            if vm.glassStyle {
                // Размытие всегда на месте и только проявляется — без вставки/удаления слоя,
                // поэтому стекло не «отстаёт» от формы во время анимации.
                VisualEffectBlur(material: .hudWindow)
                    .opacity(glass ? 1 : 0)
                Theme.glassTint.opacity(glass ? 0.16 : 0)
            }
            Color.black.opacity(glass ? 0 : 1)

            if let backdrop = backdropImage {
                Image(nsImage: backdrop)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .opacity(glass ? 0.45 : 0.5)
                    .mask {
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0.08), .init(color: .black, location: 0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .id(ObjectIdentifier(backdrop))
                    .transition(.opacity.animation(.easeInOut(duration: 0.6)))
            }

            if lifted {
                // Мягкий блик снизу и затемнение для читаемости.
                RadialGradient(colors: [.white.opacity(glass ? 0.12 : 0.05), .clear], center: UnitPoint(x: 0.15, y: 1.05), startRadius: 0, endRadius: 320)
                LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .center, endPoint: .bottom)
            }

            if vm.isDropTargeted {
                Color.white.opacity(0.08)
            }
        }
        .allowsHitTesting(false)
    }

    private var backdropImage: NSImage? {
        switch vm.presentation {
        case .open:
            return vm.tab == .home ? vm.selectedItem?.backdrop : nil
        case .banner(let banner):
            return banner.icon == .artwork ? vm.nowPlaying.items.first?.backdrop : nil
        case .closed:
            return nil
        }
    }
}
