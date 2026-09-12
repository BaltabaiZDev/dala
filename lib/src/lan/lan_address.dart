const int lanDefaultPort = 7777;

/// Explicit ports win over the saved default; a plain IP needs no suffix.
Uri lanAddressUri(String raw, {int defaultPort = lanDefaultPort}) {
  var value = raw.trim();
  if (value.isEmpty) throw const FormatException('Хост IP бос.');
  if (RegExp(r'\s').hasMatch(value)) {
    throw const FormatException('Хост IP жарамсыз.');
  }
  if (defaultPort < 1 || defaultPort > 65535) {
    throw const FormatException('Порт 1–65535 аралығында болуы керек.');
  }
  // A bare IPv6 address is a host, not a host:port pair.
  if (!value.contains('://') &&
      !value.startsWith('[') &&
      ':'.allMatches(value).length > 1) {
    value = '[$value]';
  }
  if (!value.contains('://')) value = 'ws://$value';
  late final Uri uri;
  try {
    uri = Uri.parse(value);
  } on FormatException {
    throw const FormatException('Хост IP жарамсыз.');
  }
  if (!const {'ws', 'wss', 'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      Uri.decodeComponent(uri.host).contains(RegExp(r'\s')) ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/' && uri.path != '/ws')) {
    throw const FormatException('Хост IP жарамсыз.');
  }
  // Uri normalizes explicit HTTP :80 / HTTPS :443 away. Preserve the user's
  // written port before switching the scheme to WebSocket.
  final authority = value
      .substring(value.indexOf('://') + 3)
      .split(RegExp(r'[/#?]'))
      .first;
  final explicitPort = RegExp(r':([0-9]+)$').firstMatch(authority)?.group(1);
  final port = explicitPort != null
      ? int.parse(explicitPort)
      : (uri.hasPort ? uri.port : defaultPort);
  if (port < 1 || port > 65535) {
    throw const FormatException('Порт 1–65535 аралығында болуы керек.');
  }
  return Uri(
    scheme: const {'wss', 'https'}.contains(uri.scheme) ? 'wss' : 'ws',
    host: uri.host,
    port: port,
    path: '/ws',
  );
}

class LanInterfaceAddress {
  const LanInterfaceAddress(this.address, this.interfaceName);
  final String address, interfaceName;
  int get priority {
    final name = interfaceName.toLowerCase();
    if (address.startsWith('127.') || address == '0.0.0.0') return -1000;
    var score =
        address.startsWith('192.168.') ||
            address.startsWith('10.') ||
            RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(address)
        ? 40
        : 0;
    if (RegExp(r'wlan|wi-?fi|swlan|hotspot|^ap\d').hasMatch(name)) score += 100;
    if (RegExp(
      r'vpn|virtual|vethernet|vmnet|vbox|docker|^br-|^tun|^utun|^tap|^wg',
    ).hasMatch(name)) {
      score -= 200;
    } else if (RegExp(r'ethernet|^eth|^en\d').hasMatch(name)) {
      score += 60;
    }
    if (address.startsWith('169.254.')) score -= 100;
    return score;
  }
}

List<String> rankedLanAddresses(Iterable<LanInterfaceAddress> interfaces) {
  final sorted = interfaces.toList()
    ..sort((a, b) {
      final rank = b.priority.compareTo(a.priority);
      return rank != 0 ? rank : a.address.compareTo(b.address);
    });
  return {...sorted.map((entry) => entry.address), '127.0.0.1'}.toList();
}
