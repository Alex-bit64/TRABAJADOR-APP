import 'package:flutter_test/flutter_test.dart';
import 'package:trabajador_app/services/qr_service.dart';

void main() {
  test('QRValidado conserva los datos necesarios para la cola offline', () {
    const qr = QRValidado(
      token: 'token-estatico',
      idSede: 'sede-1',
      nombreSede: 'Sede Centro',
      idTienda: 'tienda-1',
      nombreTienda: 'Tienda Centro',
      direccion: 'Av. Principal 123',
      ubicacionQr: {'latitud': -12.04, 'longitud': -77.03},
    );

    final restaurado = QRValidado.fromMap(qr.toMap());

    expect(restaurado.token, qr.token);
    expect(restaurado.idTienda, qr.idTienda);
    expect(restaurado.nombreTienda, qr.nombreTienda);
    expect(restaurado.ubicacionQr, qr.ubicacionQr);
  });
}
