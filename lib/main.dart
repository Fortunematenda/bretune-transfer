import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'theme/app_theme.dart';
import 'transfer_service.dart';

void main() => runApp(const BretuneTransferApp());

class BretuneTransferApp extends StatelessWidget {
  const BretuneTransferApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Bretune Transfer',
      theme: buildAppTheme(),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final TransferService service;
  bool loading = true;
  String? error;
  int tab = 0;
  final _seenDeviceIds = <String>{};
  final _offerQueue = <PendingOffer>[];
  Completer<bool>? _offerAnswer;

  @override
  void initState() {
    super.initState();
    service = TransferService(
      onChanged: () {
        if (!mounted) return;
        if (tab == 0) {
          unawaited(_acknowledgeDevices(persist: true));
        } else {
          setState(() {});
        }
      },
      onOffer: _onOffer,
    );
    service.start().then((_) async {
      await _loadSeenDevices();
      if (tab == 0) await _acknowledgeDevices(persist: true);
      if (mounted) setState(() => loading = false);
    }).catchError((e) {
      if (mounted) {
        setState(() {
        loading = false;
        error = e.toString();
      });
      }
    });
  }

  Future<bool> _onOffer(PendingOffer offer) async {
    if (service.autoAcceptFromPaired) return true;
    _offerQueue.add(offer);
    if (_offerAnswer != null) return false;
    while (_offerQueue.isNotEmpty && mounted) {
      final current = _offerQueue.removeAt(0);
      _offerAnswer = Completer<bool>();
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final answer = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.download_rounded, size: 42),
            title: const Text('Incoming file'),
            content: Text(
              '${current.sender} wants to send:\n\n${current.fileName}\n${prettyBytes(current.size)}\n\nThe file will be saved in your selected destination.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Reject')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Accept')),
            ],
          ),
        );
        _offerAnswer?.complete(answer ?? false);
      });
      final result = await _offerAnswer!.future;
      _offerAnswer = null;
      return result;
    }
    return false;
  }

  @override
  void dispose() {
    service.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Scaffold(
        backgroundColor: AppColors.surface,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const BrandLogo(height: 72),
              const SizedBox(height: 28),
              CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
            ],
          ),
        ),
      );
    }
    if (error != null) {
      return Scaffold(body: _ErrorView(message: error!));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = AppBreakpoints.isCompact(constraints.maxWidth);
        final body = AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: switch (tab) {
            0 => _DevicesView(key: const ValueKey(0), service: service, send: _pickAndSend),
            1 => _TransfersView(key: const ValueKey(1), service: service),
            _ => _SettingsView(key: const ValueKey(2), service: service, chooseFolder: _chooseReceiveFolder, scanQr: _openQrScanner),
          },
        );

        if (compact) {
          return Scaffold(
            appBar: _buildAppBar(compact: true),
            body: body,
            bottomNavigationBar: _buildBottomNav(),
          );
        }

        return Scaffold(
          appBar: _buildAppBar(compact: false),
          body: Row(
            children: [
              _buildRail(),
              Expanded(child: body),
            ],
          ),
        );
      },
    );
  }

  int get _unseenDeviceCount {
    if (tab == 0) return 0;
    return service.devices.keys.where((id) => !_seenDeviceIds.contains(id)).length;
  }

  bool get _showTransferBadge =>
      tab != 1 && service.transfers.any((t) => t.state == TransferState.sending || t.state == TransferState.receiving);

  Future<void> _loadSeenDevices() async {
    final prefs = await SharedPreferences.getInstance();
    _seenDeviceIds
      ..clear()
      ..addAll(prefs.getStringList('seenDeviceIds') ?? const []);
  }

  Future<void> _acknowledgeDevices({bool persist = false}) async {
    _seenDeviceIds.addAll(service.devices.keys);
    if (mounted) setState(() {});
    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('seenDeviceIds', _seenDeviceIds.toList());
    }
  }

  void _onTabSelected(int index) {
    tab = index;
    if (index == 0) {
      unawaited(_acknowledgeDevices(persist: true));
    } else {
      setState(() {});
    }
  }

  PreferredSizeWidget _buildAppBar({required bool compact}) {
    return AppBar(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BrandLogo(height: 36),
          const SizedBox(width: 12),
          const Text('Bretune Transfer'),
        ],
      ),
      actions: [
        if (!compact)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.tonalIcon(
              onPressed: _chooseReceiveFolder,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: const Text('Receive folder'),
            ),
          )
        else
          IconButton(
            onPressed: _chooseReceiveFolder,
            tooltip: 'Receive folder',
            icon: const Icon(Icons.folder_open_rounded),
          ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _devicesTabIcon({required bool selected}) {
    final count = _unseenDeviceCount;
    return Badge(
      isLabelVisible: !selected && count > 0,
      label: Text('$count'),
      child: const Icon(Icons.devices_rounded),
    );
  }

  Widget _transfersTabIcon({required bool selected}) {
    return Badge(
      isLabelVisible: !selected && _showTransferBadge,
      smallSize: 8,
      child: const Icon(Icons.sync_alt_rounded),
    );
  }

  NavigationBar _buildBottomNav() {
    return NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: _onTabSelected,
      destinations: [
        NavigationDestination(
          icon: _devicesTabIcon(selected: false),
          selectedIcon: _devicesTabIcon(selected: true),
          label: 'Devices',
        ),
        NavigationDestination(
          icon: _transfersTabIcon(selected: false),
          selectedIcon: _transfersTabIcon(selected: true),
          label: 'Transfers',
        ),
        const NavigationDestination(icon: Icon(Icons.settings_rounded), label: 'Settings'),
      ],
    );
  }

  Widget _buildRail() {
    return NavigationRail(
      key: ValueKey('nav-rail-$tab-$_unseenDeviceCount-$_showTransferBadge'),
      selectedIndex: tab,
      onDestinationSelected: _onTabSelected,
      labelType: NavigationRailLabelType.all,
      destinations: [
        NavigationRailDestination(
          icon: _devicesTabIcon(selected: false),
          selectedIcon: _devicesTabIcon(selected: true),
          label: const Text('Devices'),
        ),
        NavigationRailDestination(
          icon: _transfersTabIcon(selected: false),
          selectedIcon: _transfersTabIcon(selected: true),
          label: const Text('Transfers'),
        ),
        const NavigationRailDestination(icon: Icon(Icons.settings_rounded), label: Text('Settings')),
      ],
    );
  }

  Future<void> _chooseReceiveFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose a folder for received files');
    if (path == null || !mounted) return;
    final resolved = await service.setCustomDestination(path);
    if (!mounted) return;
    if (Platform.isAndroid && resolved != path) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Files will be saved to:\n$resolved')),
      );
    }
  }

  Future<bool?> _askSendMode(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('What do you want to send?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: const Text('Files'),
                subtitle: const Text('Pick one or more files'),
                onTap: () => Navigator.pop(context, false),
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Folder'),
                subtitle: const Text('Send a folder with all files inside'),
                onTap: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndSend(NearbyDevice device) async {
    try {
      if (!service.isPaired(device)) {
        final paired = await _showPairing(device);
        if (!paired || !mounted) return;
      }
      final sendFolder = await _askSendMode(context);
      if (sendFolder == null || !mounted) return;

      final destinations = await service.fetchDestinations(device);
      if (!mounted) return;
      final destination = await _pickDestination(context, destinations);
      if (destination == null) return;
      setState(() => tab = 1);

      if (sendFolder) {
        final dirPath = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Select folder to send');
        if (dirPath == null || !mounted) return;
        final count = await service.sendDirectory(device, dirPath, destination);
        if (!mounted) return;
        if (count == 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No files found in that folder.')),
          );
        }
        return;
      }

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
        withReadStream: true,
        dialogTitle: 'Select files to send',
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      for (final selected in result.files) {
        unawaited(service.sendPlatformFile(device, selected, destination));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send: $e')));
      }
    }
  }

  Future<Destination?> _pickDestination(BuildContext context, List<Destination> destinations) {
    final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.compact;
    final content = SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Choose destination folder', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            ...destinations.map(
              (d) => Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: Icon(Icons.folder_rounded, color: Theme.of(context).colorScheme.primary),
                  title: Text(d.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(d.detail, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, d),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (compact) {
      return showModalBottomSheet<Destination>(context: context, showDragHandle: true, builder: (_) => content);
    }
    return showDialog<Destination>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose destination'),
        content: SizedBox(width: 420, child: content),
      ),
    );
  }

  Future<bool> _openQrScanner() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission is required to scan a pairing QR code.')),
        );
      }
      return false;
    }
    if (!mounted) return false;
    return await Navigator.push<bool>(
          context,
          MaterialPageRoute(builder: (_) => _QrScanner(service: service)),
        ) ??
        false;
  }

  Future<bool> _showPairing(NearbyDevice device) async {
    final controller = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.lock_outline_rounded, size: 42),
        title: Text('Pair with ${device.name}'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter the six-digit PIN from the other device Settings screen, or scan its QR code on Android.'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 8),
                decoration: const InputDecoration(labelText: 'Pairing PIN', counterText: ''),
              ),
            ],
          ),
        ),
        actions: [
          if (Platform.isAndroid)
            TextButton.icon(
              onPressed: () async {
                final paired = await _openQrScanner();
                if (context.mounted && paired) Navigator.pop(context, true);
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR'),
            ),
          FilledButton(
            onPressed: () async {
              final pairingError = await service.pairWithPin(device, controller.text.trim());
              if (!context.mounted) return;
              if (pairingError == null) {
                Navigator.pop(context, true);
                return;
              }
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(pairingError)));
            },
            child: const Text('Pair'),
          ),
        ],
      ),
    );
    if (result != true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pairing failed. Check the PIN or make sure both devices are on the same Wi-Fi.')),
      );
    }
    return result ?? false;
  }
}

class _DevicesView extends StatelessWidget {
  const _DevicesView({required this.service, required this.send, super.key});

  final TransferService service;
  final Future<void> Function(NearbyDevice) send;

  @override
  Widget build(BuildContext context) {
    final devices = service.devices.values.toList();
    return ContentContainer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = AppBreakpoints.deviceColumns(constraints.maxWidth);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _HeroCard(deviceName: service.deviceName, deviceCount: devices.length)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 28, bottom: 14),
                  child: PageHeader(
                    title: 'Nearby devices',
                    subtitle: 'Devices on the same Wi-Fi network appear here automatically.',
                    trailing: StatusChip(label: '${devices.length} found', color: Theme.of(context).colorScheme.primary),
                  ),
                ),
              ),
              if (devices.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.devices_other_rounded,
                    title: 'No devices found yet',
                    message: 'Open Bretune Transfer on another phone or laptop connected to the same Wi-Fi.',
                  ),
                )
              else
                SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    childAspectRatio: columns == 1 ? 2.8 : 1.55,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _DeviceCard(device: devices[index], service: service, send: send),
                    childCount: devices.length,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.deviceName, required this.deviceCount});

  final String deviceName;
  final int deviceCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.heroStart, AppColors.heroEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: AppColors.heroStart.withValues(alpha: 0.28),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > 520;
          final info = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(deviceName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22)),
              const SizedBox(height: 6),
              const Text('Visible on this Wi-Fi network', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  const _HeroPill(icon: Icons.wifi_tethering_rounded, label: 'Broadcasting'),
                  _HeroPill(icon: Icons.devices_rounded, label: '$deviceCount nearby'),
                ],
              ),
            ],
          );

          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.white24,
                  child: Icon(Icons.wifi_tethering_rounded, color: Colors.white, size: 30),
                ),
                const SizedBox(height: 16),
                info,
              ],
            );
          }

          return Row(
            children: [
              const CircleAvatar(
                radius: 32,
                backgroundColor: Colors.white24,
                child: Icon(Icons.wifi_tethering_rounded, color: Colors.white, size: 34),
              ),
              const SizedBox(width: 18),
              Expanded(child: info),
            ],
          );
        },
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12)),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device, required this.service, required this.send});

  final NearbyDevice device;
  final TransferService service;
  final Future<void> Function(NearbyDevice) send;

  @override
  Widget build(BuildContext context) {
    final paired = service.isPaired(device);
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    device.platform == 'Windows' ? Icons.laptop_windows_rounded : Icons.phone_iphone_rounded,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(device.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text(device.platform, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                StatusChip(
                  label: paired ? 'Paired' : 'Pairing required',
                  color: paired ? AppColors.success : AppColors.warning,
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => send(device),
                  icon: Icon(paired ? Icons.send_rounded : Icons.lock_outline_rounded, size: 18),
                  label: Text(paired ? 'Send' : 'Pair'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TransfersView extends StatefulWidget {
  const _TransfersView({required this.service, super.key});

  final TransferService service;

  @override
  State<_TransfersView> createState() => _TransfersViewState();
}

enum _TransferFilter { all, succeeded, failed }

class _TransfersViewState extends State<_TransfersView> {
  _TransferFilter filter = _TransferFilter.all;

  List<TransferRecord> get _filtered {
    final records = widget.service.transfers;
    return switch (filter) {
      _TransferFilter.all => records,
      _TransferFilter.succeeded => records.where((r) => r.state == TransferState.complete).toList(),
      _TransferFilter.failed => records.where((r) => r.state == TransferState.failed || r.state == TransferState.rejected).toList(),
    };
  }

  int _countFor(_TransferFilter value) {
    final records = widget.service.transfers;
    return switch (value) {
      _TransferFilter.all => records.length,
      _TransferFilter.succeeded => records.where((r) => r.state == TransferState.complete).length,
      _TransferFilter.failed => records.where((r) => r.state == TransferState.failed || r.state == TransferState.rejected).length,
    };
  }

  Future<void> _resend(TransferRecord record) async {
    final error = await widget.service.resendTransfer(record);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = _filtered;
    final theme = Theme.of(context);

    if (widget.service.transfers.isEmpty) {
      return const ContentContainer(
        child: EmptyState(
          icon: Icons.history_rounded,
          title: 'No transfers yet',
          message: 'Sent and received files will appear here with live progress and status.',
        ),
      );
    }

    return ContentContainer(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const PageHeader(
                  title: 'Transfer history',
                  subtitle: 'Transfers from this session. History is cleared when you close the app.',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _HistoryFilterChip(
                      label: 'All (${_countFor(_TransferFilter.all)})',
                      selected: filter == _TransferFilter.all,
                      onTap: () => setState(() => filter = _TransferFilter.all),
                    ),
                    _HistoryFilterChip(
                      label: 'Delivered (${_countFor(_TransferFilter.succeeded)})',
                      selected: filter == _TransferFilter.succeeded,
                      color: AppColors.success,
                      onTap: () => setState(() => filter = _TransferFilter.succeeded),
                    ),
                    _HistoryFilterChip(
                      label: 'Failed (${_countFor(_TransferFilter.failed)})',
                      selected: filter == _TransferFilter.failed,
                      color: theme.colorScheme.error,
                      onTap: () => setState(() => filter = _TransferFilter.failed),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
              ],
            ),
          ),
          if (records.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: filter == _TransferFilter.succeeded ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                title: filter == _TransferFilter.succeeded ? 'No delivered transfers yet' : 'No failed transfers',
                message: filter == _TransferFilter.succeeded
                    ? 'Delivered sends and receives will appear in this list with the saved file path.'
                    : 'Failed or rejected transfers will appear here with a resend option.',
              ),
            )
          else
            SliverList.separated(
              itemCount: records.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) => _TransferCard(
                record: records[index],
                onResend: records[index].canResend ? () => _resend(records[index]) : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _HistoryFilterChip extends StatelessWidget {
  const _HistoryFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.primary;
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      labelStyle: TextStyle(
        fontWeight: FontWeight.w700,
        color: selected ? accent : theme.colorScheme.onSurfaceVariant,
      ),
      selectedColor: accent.withValues(alpha: 0.14),
      side: BorderSide(color: selected ? accent.withValues(alpha: 0.35) : theme.colorScheme.outlineVariant),
    );
  }
}

class _TransferCard extends StatelessWidget {
  const _TransferCard({required this.record, this.onResend});

  final TransferRecord record;
  final VoidCallback? onResend;

  Color _statusColor(ThemeData theme) {
    return switch (record.state) {
      TransferState.complete => AppColors.success,
      TransferState.failed || TransferState.rejected => theme.colorScheme.error,
      TransferState.sending || TransferState.receiving => theme.colorScheme.primary,
      TransferState.waiting => AppColors.warning,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = record.state == TransferState.sending || record.state == TransferState.receiving;
    final statusColor = _statusColor(theme);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: record.incoming ? theme.colorScheme.secondaryContainer : theme.colorScheme.primaryContainer,
                  child: Icon(record.incoming ? Icons.south_rounded : Icons.north_rounded),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(record.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(
                        '${record.incoming ? 'From' : 'To'} ${record.peer} • ${prettyBytes(record.total)}',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      if (record.finishedAt != null) ...[
                        const SizedBox(height: 4),
                        Text(formatTransferTime(record.finishedAt), style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12)),
                      ],
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    StatusChip(label: record.statusLabel, color: statusColor),
                    const SizedBox(height: 8),
                    _StateIcon(state: record.state),
                  ],
                ),
              ],
            ),
            if (active) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(minHeight: 8, value: record.progress),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Text('${(record.progress * 100).toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
            if (record.state == TransferState.complete && record.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.folder_outlined, size: 16, color: AppColors.success),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Saved to', style: TextStyle(color: AppColors.success, fontSize: 12, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(
                            record.message,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            else if (record.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  record.message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: record.state == TransferState.failed || record.state == TransferState.rejected
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            if (onResend != null) ...[
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: onResend,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Resend'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.state});

  final TransferState state;

  @override
  Widget build(BuildContext context) {
    if (state == TransferState.complete) {
      return const Icon(Icons.check_circle_rounded, color: AppColors.success);
    }
    if (state == TransferState.failed || state == TransferState.rejected) {
      return Icon(Icons.error_rounded, color: Theme.of(context).colorScheme.error);
    }
    return const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2));
  }
}

class _SettingsView extends StatelessWidget {
  const _SettingsView({required this.service, required this.chooseFolder, required this.scanQr, super.key});

  final TransferService service;
  final VoidCallback chooseFolder;
  final Future<bool> Function() scanQr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final receiveFolder = service.destinations.isNotEmpty ? service.destinations.last.detail : 'Not set';

    return ContentContainer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= AppBreakpoints.compact;
          final settingsCard = _SettingsCard(
            children: [
              _SettingsTile(
                icon: Icons.badge_outlined,
                title: 'Device name',
                subtitle: service.deviceName,
              ),
              const Divider(height: 1),
              _SettingsTile(
                icon: Icons.qr_code_rounded,
                title: 'Pair this device',
                subtitle: 'PIN: ${service.pairingPin}',
                subtitleStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 4),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (Platform.isAndroid)
                      IconButton(
                        icon: const Icon(Icons.qr_code_scanner),
                        tooltip: 'Scan pairing QR',
                        onPressed: () async {
                          final paired = await scanQr();
                          if (paired && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Device paired successfully.')),
                            );
                          }
                        },
                      ),
                    IconButton(
                      icon: const Icon(Icons.open_in_new_rounded),
                      onPressed: () => showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Pairing QR code'),
                          content: SizedBox(
                            width: 280,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: QrImageView(data: service.qrPayload, size: 220),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Scan from Bretune Transfer on another device.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              _SettingsTile(
                icon: Icons.folder_open_rounded,
                title: 'Receive folder',
                subtitle: receiveFolder,
                onTap: chooseFolder,
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.security_rounded),
                title: const Text('Auto-accept from paired devices'),
                subtitle: Text(
                  service.autoAcceptFromPaired
                      ? 'Linked devices can send without asking each time'
                      : 'You approve every incoming file',
                ),
                value: service.autoAcceptFromPaired,
                onChanged: service.setAutoAcceptFromPaired,
              ),
            ],
          );

          final privacyCard = Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Privacy: files move directly between paired devices on your local Wi-Fi. Bretune Transfer does not upload files to a cloud server.',
                      style: TextStyle(height: 1.45, color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          );

          if (!wide) {
            return ListView(
              children: [
                const PageHeader(title: 'Settings', subtitle: 'Manage pairing, folders, and transfer approval.'),
                const SizedBox(height: 16),
                settingsCard,
                const SizedBox(height: 16),
                privacyCard,
              ],
            );
          }

          return ListView(
            children: [
              const PageHeader(title: 'Settings', subtitle: 'Manage pairing, folders, and transfer approval.'),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: settingsCard),
                  const SizedBox(width: 16),
                  Expanded(child: privacyCard),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(child: Column(children: children));
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.subtitleStyle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final TextStyle? subtitleStyle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: subtitleStyle),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

class _QrScanner extends StatefulWidget {
  const _QrScanner({required this.service});

  final TransferService service;

  @override
  State<_QrScanner> createState() => _QrScannerState();
}

class _QrScannerState extends State<_QrScanner> {
  bool busy = false;
  late final MobileScannerController controller;

  @override
  void initState() {
    super.initState();
    controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates, facing: CameraFacing.back);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _handleScan(String value) async {
    if (busy) return;
    busy = true;
    final error = await widget.service.pairWithQr(value);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
      return;
    }
    busy = false;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan pairing QR'),
        actions: [
          IconButton(
            icon: ValueListenableBuilder(
              valueListenable: controller,
              builder: (context, state, child) {
                switch (state.torchState) {
                  case TorchState.off:
                    return const Icon(Icons.flash_off_rounded);
                  case TorchState.on:
                    return const Icon(Icons.flash_on_rounded);
                  default:
                    return const Icon(Icons.flash_off_rounded);
                }
              },
            ),
            onPressed: () => controller.toggleTorch(),
          ),
        ],
      ),
      body: MobileScanner(
        controller: controller,
        onDetect: (capture) async {
          if (capture.barcodes.isEmpty) return;
          final value = capture.barcodes.first.rawValue;
          if (value == null) return;
          await _handleScan(value);
        },
        errorBuilder: (context, error, child) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? 'Camera permission is required. Enable it in Android Settings and try again.'
                    : 'Could not open the camera (${error.errorCode.name}).',
                textAlign: TextAlign.center,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off_rounded, size: 60, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              const Text('Could not start local transfer service', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
