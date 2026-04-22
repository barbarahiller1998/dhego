# Firestore Import

1. In Firebase / Google Cloud create a service account key JSON for your project.
2. Copy `seed_data.example.json` to your own file, for example `seed_data.json`.
3. Fill it with your real data.
4. Run:

```powershell
flutter pub get
dart run tool/firestore_import.dart --credentials C:\path\service-account.json --data seed\seed_data.json
```

Optional:

```powershell
dart run tool/firestore_import.dart --credentials C:\path\service-account.json --data seed\seed_data.json --project dhego-fb024
```

The importer upserts documents by `id`, so you can run it multiple times.
