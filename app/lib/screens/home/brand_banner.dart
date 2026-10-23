part of '../home_screen.dart';

/// 장식은 과업보다 먼저 커지지 않는다. 큰 글씨에서는 반복 브랜드 배너를 생략한다.
class _BrandBanner extends StatelessWidget {
  const _BrandBanner();
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
      return const SizedBox.shrink();
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ExcludeSemantics(
        child: Container(
      key: const Key('home-brand-banner'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
          color: dark ? AppColors.brandBanner : AppColors.brandBannerLight,
          borderRadius: BorderRadius.circular(16)),
      child: Stack(children: [
        Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('SimpleLay',
                        style: TextStyle(
                            fontSize: AppFont.caption,
                            fontWeight: FontWeight.w600,
                            color: context.appPrimary)),
                    const SizedBox(height: AppSpace.xs),
                    Text(keepWordsTogether('복잡한 가전을 더 간단하게'),
                        style: TextStyle(
                            fontSize: AppFont.body,
                            fontWeight: FontWeight.w800,
                            color: context.appPrimary)),
                  ])),
              const SizedBox(width: AppSpace.xxxl + AppSpace.xl),
            ])),
        Positioned(
            right: AppSpace.sm,
            bottom: -AppSpace.sm,
            child: TouchMark(
                ink: context.appPrimary, button: context.appPrimary, size: 80)),
      ]),
    ));
  }
}
