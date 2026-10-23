# Logi Options+ Debloat untuk macOS

Skrip mandiri untuk menonaktifkan fitur tambahan pada instalasi Logi Options+ yang sudah ada. Memerlukan macOS 12 atau lebih baru. Tidak memerlukan Python, Node.js, Homebrew, atau unduhan lain. Bukan skrip Windows.

## Cara pakai

1. Ekstrak ZIP ke folder biasa.
2. Klik dua kali **Check.command** untuk memeriksa instalasi dan rencana perubahan tanpa mengubah pengaturan.
3. Klik dua kali **LogiOptions-Debloat.command** untuk menerapkan. Jalankan sebagai akun desktop biasa. Terminal dapat meminta password administrator melalui `sudo` khusus untuk mengganti file kebijakan secara atomik, sambil mempertahankan pemilik dan mode izinnya. Karakter password memang tidak ditampilkan.
4. Klik dua kali **Restore.command** untuk memulihkan nilai fitur dari cadangan terakhir di akun yang sama.

Alternatif melalui Terminal, dari folder hasil ekstraksi:

```sh
zsh ./LogiOptions-Debloat.command --dry-run
zsh ./LogiOptions-Debloat.command
zsh ./LogiOptions-Debloat.command --status
zsh ./LogiOptions-Debloat.command --restore
```

Jika macOS tidak membuka berkas `.command`, gunakan perintah `zsh` di Terminal dari folder ekstraksi. Jangan menjalankan seluruh skrip dengan `sudo`.

## Yang berubah

- Kebijakan `analytics`, `flow`, `sso`, `logivoice`, `aipromptbuilder`, `device_recommendation`, `smartactions`, dan `actions_ring` menjadi `false`, bila field tersebut tersedia.
- Preferensi menjalankan Logi Plugin Service di latar belakang menjadi nonaktif bila layanan atau preferensinya ditemukan.
- Antarmuka Options+ ditutup, proses Plugin Service dihentikan dengan SIGTERM, dan agent perangkat resmi dimuat ulang. Tombol khusus mungkin berhenti sebentar selama restart.

Flow antar-komputer, backup/login cloud, macro Smart Actions, Actions Ring, serta tindakan yang memakai plugin tidak tersedia selama dinonaktifkan. Assignment perangkat biasa tidak disunting. Nilai update aplikasi, firmware/DFU, backlight, dan field lain dipertahankan sesuai keadaan sebelumnya.

Skrip tidak menghapus aplikasi atau data Marketplace, tidak mengubah ASAR/binary bertanda tangan, dan tidak menyalin profil/database mouse. Menjalankannya lagi saat pengaturan sudah sesuai tidak membuat cadangan baru. Tidak dibuat monitor, LaunchAgent tambahan, atau tugas terjadwal.

## Cadangan

Cadangan dibuat secara lokal di:

```text
~/Library/Application Support/LogiOptionsDebloat/backups/
```

Cadangan hanya berisi kebijakan fitur, manifest pemulihan, dan hasil kebijakan yang dipersiapkan. Paket ZIP ini tidak berisi cadangan, username, database, akun, atau konfigurasi mouse milik pembuatnya.

Pemulihan menggabungkan kembali nilai delapan field yang tersedia pada cadangan dan instalasi sekarang. Field baru serta pengaturan perangkat sesudah perampingan dipertahankan. Preferensi LPS dikembalikan ke nilai semula, atau dihapus jika sebelumnya belum ada. Cadangan dari akun/lokasi instalasi berbeda ditolak.

Untuk memilih cadangan lama:

```sh
zsh ./LogiOptions-Debloat.command --restore "/lokasi/folder/cadangan"
```

## Cakupan dan batasan

Perubahan dasarnya telah diperiksa pada Logi Options+ 2.9.984725 dan 2.9.994631 di macOS dengan MX Master 3. Transformasi skrip diuji memakai berkas contoh; pemasangan pada Mac teman Anda tetap harus diverifikasi dengan perangkatnya. Skrip berhenti jika lokasi ambigu, struktur field dikenal berubah, atau LaunchAgent resmi tidak ditemukan. Field opsional yang tidak ada tidak ditambahkan.

AI Portal merupakan komponen terpisah pada beberapa build. Pada instalasi yang diperiksa, depot AI Portal/Voice difilter dan aplikasinya tidak terpasang. `aipromptbuilder=false` tidak membuktikan semua implementasi AI pada versi masa depan ikut dinonaktifkan. Skrip tidak menambahkan flag rekaan atau menghapus binary AI yang tidak dikenal.

Electron tetap digunakan ketika antarmuka dibuka. Menutup aplikasi setelah mengatur mouse membantu mengurangi proses yang berjalan, tetapi skrip tidak menjamin angka RAM tertentu. Periksa ulang setelah reinstall atau pembaruan besar.

Skrip memeriksa bahwa agent berjalan setelah perubahan. Tetap uji tombol, scroll, gesture, dan assignment yang Anda gunakan. Jika terjadi kegagalan setelah penulisan, lokasi cadangan ditampilkan; jalankan `Restore.command` untuk membatalkan perubahan konfigurasi. Bila updater Logitech sedang memasang build baru, tunggu sampai selesai sebelum menjalankan lagi.

## Dasar teknis

Kebijakan berasal dari mekanisme `app_permissions.json` pada instalasi yang dianalisis dengan REA. [Dokumentasi feature flags Logitech](https://hub.sync.logitech.com/options/post/options-silent-installation-feature-flags-RnX8O7v5xTQ41mq) menjelaskan kontrol fitur installer. Pengeditan langsung file kebijakan oleh skrip ini berdasarkan pemeriksaan lokal, bukan metode pengeditan yang dijanjikan vendor.

## Pengembangan dan pengujian

Clone repository atau unduh melalui **Code → Download ZIP**, lalu jalankan perintah di atas dari folder hasil clone/ekstraksi. File `.command` harus tetap berada dalam folder yang sama.

Pengujian lokal memakai macOS dan Python 3 hanya sebagai alat pengembangan. Pengguna skrip utama tidak memerlukan Python.

```sh
for script in *.command tests/*.zsh; do zsh -n "$script" || exit 1; done
zsh tests/test-policy.zsh
```

Pengujian memakai fixture dalam folder sementara, tidak menerapkan perampingan pada instalasi Logitech. Cakupannya meliputi delapan flag, pelestarian field lain dan Unicode, pengulangan yang tidak mengubah hasil, pemulihan, field yang belum tersedia, penolakan skema/symlink, verifikasi yang gagal, serta penggantian file atomik dengan pemilik dan mode izin tetap.
