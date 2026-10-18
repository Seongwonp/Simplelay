part of '../settings_screen.dart';

// ── 설정 탭 첫 묶음(UI 확정 §2) ──────────────────────────────────────────────

/// 설정 한 화면의 줄 문법 하나(평가 15차 10/18: 테두리 묶음·면 없는 목록·구분선 목록이 한 화면에 섞였고, 왼쪽 아이콘·
/// 오른쪽 화살표 열이 줄마다 어긋났다). 모든 줄 = 안쪽 여백 [kSettingsRowInset] · 아이콘 24 · 간격 [kSettingsRowInset] ·
/// 이름(+값 오른쪽) · 화살표. 묶음은 테두리 없이 줄 사이 옅은 구분선만.
const kSettingsRowInset = AppSpace.lg;

/// 설정 첫 화면의 [ListTile]·[SwitchListTile]이 [_ValueRow]와 같은 열에 서게 하는 테마.
ListTileThemeData settingsListTileTheme(BuildContext context) => ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: kSettingsRowInset),
      minLeadingWidth: 24,
      horizontalTitleGap: kSettingsRowInset,
      iconColor: context.appInk,
    );

/// 행 여러 개를 한 묶음으로 — 테두리·면 없이 줄 사이 구분선만(평가 15차 10/18).
class _NavGroup extends StatelessWidget {
  const _NavGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('settings-nav-group'),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i < children.length - 1)
                Divider(height: 1, color: context.appBorderFaint),
            ],
          ],
        ),
      );
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.valueColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// 값 글자 색 — 볼 것이 있을 때만 경고색(평가 15차 10/18: 빨간 숫자 칩과 '안 본 알림 7건' 글자가 같은 말을 두 번 했다 →
  /// 칩 없이 글자 하나, 색은 그 글자에).
  final Color? valueColor;

  // 한 줄 = 이름 + 오른쪽 지금 값(2026-10-18). [subtitle]은 그 값이다(설명 문장을 두지 않는다).
  @override
  Widget build(BuildContext context) => ListTile(
        minVerticalPadding: 12,
        contentPadding: const EdgeInsets.symmetric(horizontal: kSettingsRowInset),
        minLeadingWidth: 24,
        horizontalTitleGap: kSettingsRowInset,
        leading: Icon(icon, color: context.appInk),
        title: _NameValue(
          name: title,
          // 어절 단위 줄바꿈('키오스크에서/는' 방지, UI 평가 10/17). 낭독은 원문.
          value: subtitle,
          valueColor: valueColor,
        ),
        trailing: Icon(Icons.chevron_right, color: context.appMuted),
        onTap: onTap,
      );
}

/// 설정 한 줄 — 이름 + 오른쪽 지금 값 + 화살표(2026-10-18). 누르면 [detail]을 상세 화면으로 연다.
/// 긴 설명·켜고 끄기는 상세 첫 줄부터 둔다 — 첫 화면이 읽는 문서가 되지 않게.
class _ValueRow extends StatelessWidget {
  const _ValueRow({
    required this.id,
    required this.icon,
    required this.title,
    required this.value,
    required this.detail,
    this.onOpen,
    this.action,
  });

  /// 줄 아래 따로 누르는 단추(예: 못 읽은 값의 '새로 보기'). 줄 전체 누르기와 겹치지 않는 제 몫의 단추.
  final Widget? action;

  /// 상세를 열기 전에 — 값을 못 읽은 줄은 여기서 다시 읽게 한다('새로 보기').
  final VoidCallback? onOpen;

  final String id;
  final IconData icon;
  final String title;
  final String value;
  final Widget detail;

  @override
  Widget build(BuildContext context) {
    final row = _row(context);
    final extra = action;
    if (extra == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Padding(
          // 아이콘 칸만큼 들여 이름 아래에 둔다.
          padding: const EdgeInsets.only(left: AppSpace.lg + 24 + AppSpace.sm, bottom: AppSpace.xs),
          child: Align(alignment: Alignment.centerLeft, child: extra),
        ),
      ],
    );
  }

  Widget _row(BuildContext context) => Semantics(
        button: true,
        label: '$title, $value',
        excludeSemantics: true,
        child: InkWell(
          key: Key('settings-row-$id'),
          onTap: () {
            onOpen?.call();
            Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => _SettingDetailScreen(title: title, child: detail)));
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: kSettingsRowInset, vertical: AppSpace.sm),
              child: Row(children: [
                Icon(icon, color: context.appInk),
                const SizedBox(width: kSettingsRowInset),
                Expanded(
                  child: _NameValue(
                    name: title,
                    value: value,
                  ),
                ),
                Icon(Icons.chevron_right, color: context.appMuted),
              ]),
            ),
          ),
        ),
      );
}

/// 이름(왼쪽)과 지금 값(오른쪽 끝).
///
/// 둘이 한 줄에 **다 들어갈 때만** 나란히 둔다. 안 들어가면 값을 이름 아래 한 줄로 내린다 — 나란히 둔 채 줄을
/// 바꾸면 '생활 습관 알아가 / 기', '읽지 않은 알림 / 4건'처럼 이름과 값이 둘 다 갈렸다(평가 4차 10/18).
/// 큰 글씨(130% 넘게)는 늘 두 줄. 이름·값 모두 낱말 단위로만 줄을 바꾼다.
class _NameValue extends StatelessWidget {
  const _NameValue({required this.name, required this.value, this.valueColor});
  final String name;
  final String value;
  final Color? valueColor;

  static const _nameStyle = TextStyle(fontSize: AppFont.body);

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final valueStyle = TextStyle(fontSize: AppFont.caption, color: valueColor ?? context.appMuted);
    // 보통 글씨에서 이름은 나란히 둘 수 없으면 아래 줄 전체 폭을 써서 꺾이지 않는다. 큰 글씨에서는 낱말 단위로만 꺾는다.
    final big = scaler.scale(1) > 1.3;
    final nameText = Text(big ? keepWordsTogether(name) : name, semanticsLabel: name, style: _nameStyle);
    final stacked = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        nameText,
        Text(keepPhrasesTogether(value, wholeParts: scaler.scale(1) <= 1.3), semanticsLabel: value, style: valueStyle),
      ],
    );
    if (big) return stacked;
    return LayoutBuilder(builder: (context, c) {
      final dir = Directionality.of(context);
      double width(String text, TextStyle style) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
          textDirection: dir,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final w = painter.width;
        painter.dispose();
        return w;
      }

      final fits = width(name, _nameStyle) + AppSpace.md + width(value, valueStyle) <= c.maxWidth;
      if (!fits) return stacked;
      return Row(children: [
        nameText,
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Text(keepPhrasesTogether(value, wholeParts: true),
              semanticsLabel: value, textAlign: TextAlign.end, style: valueStyle),
        ),
      ]);
    });
  }
}


/// 설정 줄의 상세 — 설명 첫 줄과 조작을 담는다.
class _SettingDetailScreen extends StatelessWidget {
  const _SettingDetailScreen({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(
          padding: const EdgeInsets.all(AppSpace.xl),
          children: [child],
        ),
      );
}

// ── LG ThinQ 연결 ─────────────────────────────────────────────────────────

class _ThinqScreen extends ConsumerWidget {
  const _ThinqScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(rpiApiServiceProvider);
    final async = ref.watch(thinqOverviewProvider);
    final overview = async.valueOrNull;
    // 확인 중·확인 실패를 '계정이 연결되지 않았다'로 말하지 않는다(외부 검토 M3, 10/15).
    // 그 말은 허브가 ThinQ를 껐다고 답했을 때(404)만.
    final String headline;
    if (api == null || async.hasError) {
      headline = 'LG 가전이 연결됐는지 몰라요. 본체 연결을 봐 주세요.';
    } else if (!async.hasValue) {
      headline = '연결을 알아보는 중이에요.';
    } else if (overview == null) {
      headline = '본체에 LG 계정이 아직 연결되지 않았어요. 설치하는 분이 연결해요.';
    } else if (overview.appliances.isEmpty) {
      headline = '아직 추가한 LG 가전이 없어요. 아래에서 쓸 가전을 추가해 주세요.';
    } else {
      headline = '본체에 연결된 LG 가전이에요. '
          '가전 화면에서 지금 상태를 보고 바꿀 수 있어요. 루틴에도 넣을 수 있어요.';
    }
    return Scaffold(
      appBar: AppBar(title: const Text('LG 가전 연결')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.xl),
        children: [
          Text(
            headline,
            key: const Key('thinq-link-headline'),
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
          const _ThinqApplianceList(),
          // 계정에서 찾은 가전 — 사용자가 '추가'를 눌러야 위 목록·홈에 들어온다(2026-10-13).
          const ThinqDiscoveredSection(),
        ],
      ),
    );
  }
}

// ── 음성으로 멈추기 ───────────────────────────────────────────────────────

/// 음성 정지는 **아직 허브에 들어가지 않았다**(실행 계획 §3-3, 통신 확인 뒤
/// 착수). 켜는 스위치를 두면 되지도 않는 기능을 된다고 말하게 되므로,
/// 어떻게 동작할 것인지와 지금 상태만 적는다.
// ── 글자 크기 ─────────────────────────────────────────────────────────────

/// 앱 안에 따로 글자 크기 설정을 두지 않는다 -- 휴대폰 설정 하나로 모든 앱이
/// 같이 커지는 편이 헷갈리지 않는다. 200%까지 화면이 넘치지 않는지 확인한다.
class _TextSizeScreen extends StatelessWidget {
  const _TextSizeScreen();

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(100).round();
    return Scaffold(
      appBar: AppBar(title: const Text('글자 크기')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.xl),
        children: [
          Text('지금 글자 크기: $scale%',
              style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpace.sm),
          Text(
            '휴대폰 설정 → 디스플레이 → 글자 크기에서 바꾸면 이 앱도 함께 커져요. '
            '200%까지 화면이 잘리지 않게 만들었어요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
        ],
      ),
    );
  }
}
