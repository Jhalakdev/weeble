import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

/// Minimal UPnP IGD client. Discovers an Internet Gateway Device on the LAN
/// via SSDP and asks it to forward an external port to our local IP+port.
///
/// This is intentionally tiny and best-effort. ~80% of consumer routers
/// support UPnP IGD v1; the rest will fail and the user is shown manual
/// port-forwarding instructions.
class Upnp {
  /// Tries to map [externalPort] → (localIp, [localPort]) for [protocol].
  /// Returns the chosen external port on success; null on failure.
  static Future<int?> tryMapPort({
    required int localPort,
    required String localIp,
    int? externalPort,
    String protocol = 'TCP',
    String description = 'Weeber',
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final controlUrl = await _discoverIgdControlUrl(timeout: timeout);
      if (controlUrl == null) return null;
      final ext = externalPort ?? localPort;
      final ok = await _addPortMapping(
        controlUrl: controlUrl,
        externalPort: ext,
        internalIp: localIp,
        internalPort: localPort,
        protocol: protocol,
        description: description,
      );
      return ok ? ext : null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _discoverIgdControlUrl({required Duration timeout}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;

    const msg =
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n';

    socket.send(msg.codeUnits, InternetAddress('239.255.255.250'), 1900);

    String? location;
    final completer = Completer<String?>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      final response = String.fromCharCodes(dg.data);
      final match = RegExp(r'LOCATION:\s*(\S+)', caseSensitive: false).firstMatch(response);
      if (match != null && !completer.isCompleted) {
        location = match.group(1);
        completer.complete(location);
      }
    });

    Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    final loc = await completer.future;
    await sub.cancel();
    socket.close();
    if (loc == null) return null;

    // Fetch device description and find the WANIPConnection control URL.
    final res = await http.get(Uri.parse(loc)).timeout(timeout);
    if (res.statusCode != 200) return null;
    final doc = xml.XmlDocument.parse(res.body);
    final services = doc.findAllElements('service');
    for (final s in services) {
      final type = s.findElements('serviceType').firstOrNull?.innerText;
      if (type != null &&
          (type.contains('WANIPConnection') || type.contains('WANPPPConnection'))) {
        final ctrl = s.findElements('controlURL').firstOrNull?.innerText;
        if (ctrl == null) continue;
        final base = Uri.parse(loc);
        return base.resolve(ctrl).toString();
      }
    }
    return null;
  }

  static Future<bool> _addPortMapping({
    required String controlUrl,
    required int externalPort,
    required String internalIp,
    required int internalPort,
    required String protocol,
    required String description,
  }) async {
    final body = '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
 <s:Body>
  <u:AddPortMapping xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
   <NewRemoteHost></NewRemoteHost>
   <NewExternalPort>$externalPort</NewExternalPort>
   <NewProtocol>$protocol</NewProtocol>
   <NewInternalPort>$internalPort</NewInternalPort>
   <NewInternalClient>$internalIp</NewInternalClient>
   <NewEnabled>1</NewEnabled>
   <NewPortMappingDescription>$description</NewPortMappingDescription>
   <NewLeaseDuration>0</NewLeaseDuration>
  </u:AddPortMapping>
 </s:Body>
</s:Envelope>''';

    final res = await http.post(
      Uri.parse(controlUrl),
      headers: {
        'Content-Type': 'text/xml; charset="utf-8"',
        'SOAPAction': '"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping"',
      },
      body: body,
    );
    return res.statusCode == 200;
  }

  /// Best-effort guess at this machine's primary LAN IP.
  static Future<String?> primaryLanIp() async {
    final ifaces = await NetworkInterface.list(
      includeLinkLocal: false,
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final i in ifaces) {
      for (final addr in i.addresses) {
        if (!addr.isLoopback && addr.address.startsWith(RegExp(r'(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)'))) {
          return addr.address;
        }
      }
    }
    // Fallback: any non-loopback v4
    for (final i in ifaces) {
      for (final addr in i.addresses) {
        return addr.address;
      }
    }
    return null;
  }
}
