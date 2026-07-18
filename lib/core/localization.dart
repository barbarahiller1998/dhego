import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String languagePreferenceKey = 'selected_language';

final ValueNotifier<AppLanguage> languageNotifier = ValueNotifier<AppLanguage>(
  AppLanguage.hr,
);

enum AppLanguage { hr, de, en }

class LanguageScope extends InheritedNotifier<ValueNotifier<AppLanguage>> {
  const LanguageScope({
    super.key,
    required super.notifier,
    required super.child,
  });

  static AppLanguage of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LanguageScope>();
    return scope?.notifier?.value ?? AppLanguage.hr;
  }
}

const Map<String, Map<AppLanguage, String>>
localizedStrings = <String, Map<AppLanguage, String>>{
  'app_title': <AppLanguage, String>{
    AppLanguage.hr: 'DHEgo - Prijava',
    AppLanguage.de: 'DHEgo - Anmeldung',
    AppLanguage.en: 'DHEgo - Login',
  },
  'login_title': <AppLanguage, String>{
    AppLanguage.hr: 'Prijava',
    AppLanguage.de: 'Anmeldung',
    AppLanguage.en: 'Login',
  },
  'username': <AppLanguage, String>{
    AppLanguage.hr: 'Korisničko ime',
    AppLanguage.de: 'Benutzername',
  },
  'username_or_email': <AppLanguage, String>{
    AppLanguage.hr: 'Korisničko ime ili e-mail',
    AppLanguage.de: 'Benutzername oder E-Mail',
    AppLanguage.en: 'Username or email',
  },
  'password': <AppLanguage, String>{
    AppLanguage.hr: 'Lozinka',
    AppLanguage.de: 'Passwort',
    AppLanguage.en: 'Password',
  },
  'login_button': <AppLanguage, String>{
    AppLanguage.hr: 'Prijavi se',
    AppLanguage.de: 'Anmelden',
    AppLanguage.en: 'Sign in',
  },
  'login_error': <AppLanguage, String>{
    AppLanguage.hr: 'Pogrešno korisničko ime ili lozinka.',
    AppLanguage.de: 'Falscher Benutzername oder falsches Passwort.',
    AppLanguage.en: 'Incorrect username or password.',
  },
  'login_error_network': <AppLanguage, String>{
    AppLanguage.hr: 'Prijava nije uspjela zbog mreže ili browser postavki.',
    AppLanguage.de:
        'Die Anmeldung ist wegen Netzwerk- oder Browsereinstellungen fehlgeschlagen.',
    AppLanguage.en: 'Login failed because of network or browser settings.',
  },
  'login_error_storage': <AppLanguage, String>{
    AppLanguage.hr:
        'Prijava nije uspjela jer browser blokira lokalnu pohranu ili kolačiće.',
    AppLanguage.de:
        'Die Anmeldung ist fehlgeschlagen, weil der Browser lokalen Speicher oder Cookies blockiert.',
    AppLanguage.en:
        'Login failed because the browser is blocking local storage or cookies.',
  },
  'login_error_domain': <AppLanguage, String>{
    AppLanguage.hr:
        'Prijava nije uspjela jer domena nije dopuštena za Firebase prijavu.',
    AppLanguage.de:
        'Die Anmeldung ist fehlgeschlagen, weil die Domain für Firebase-Anmeldung nicht freigegeben ist.',
    AppLanguage.en:
        'Login failed because this domain is not authorized for Firebase sign-in.',
  },
  'login_error_disabled': <AppLanguage, String>{
    AppLanguage.hr: 'Prijava e-mailom i lozinkom trenutno nije omogućena.',
    AppLanguage.de:
        'Die Anmeldung mit E-Mail und Passwort ist derzeit nicht aktiviert.',
    AppLanguage.en: 'Email and password sign-in is not currently enabled.',
  },
  'login_error_rate_limit': <AppLanguage, String>{
    AppLanguage.hr:
        'Previše pokušaja prijave. Pričekaj malo i pokušaj ponovno.',
    AppLanguage.de:
        'Zu viele Anmeldeversuche. Bitte warte kurz und versuche es erneut.',
    AppLanguage.en: 'Too many login attempts. Please wait a bit and try again.',
  },
  'inactive_user_error': <AppLanguage, String>{
    AppLanguage.hr: 'Korisnički račun nije aktivan.',
    AppLanguage.de: 'Das Benutzerkonto ist nicht aktiv.',
    AppLanguage.en: 'This user account is not active.',
  },
  'forgot_password': <AppLanguage, String>{
    AppLanguage.hr: 'Zaboravljena lozinka?',
    AppLanguage.de: 'Passwort vergessen?',
    AppLanguage.en: 'Forgot password?',
  },
  'password_reset_sent': <AppLanguage, String>{
    AppLanguage.hr: 'Poslan je e-mail za promjenu lozinke.',
    AppLanguage.de: 'Die E-Mail zum Zurücksetzen des Passworts wurde gesendet.',
    AppLanguage.en: 'Password reset email has been sent.',
  },
  'password_reset_error': <AppLanguage, String>{
    AppLanguage.hr: 'Nije moguće poslati e-mail za promjenu lozinke.',
    AppLanguage.de:
        'Die E-Mail zum Zurücksetzen des Passworts konnte nicht gesendet werden.',
    AppLanguage.en: 'Unable to send the password reset email.',
  },
  'offline_login_success': <AppLanguage, String>{
    AppLanguage.hr:
        'Prijava je otvorena iz spremljenih podataka. Kad se spojiš na internet, podaci će se ponovno sinkronizirati.',
    AppLanguage.de:
        'Die Anmeldung wurde mit gespeicherten Daten geöffnet. Sobald wieder Internet verfügbar ist, werden die Daten erneut synchronisiert.',
  },
  'initial_password': <AppLanguage, String>{
    AppLanguage.hr: 'Početna lozinka',
    AppLanguage.de: 'Startpasswort',
  },
  'password_min_length_hint': <AppLanguage, String>{
    AppLanguage.hr: 'Lozinka mora imati najmanje 6 znakova.',
    AppLanguage.de: 'Das Passwort muss mindestens 6 Zeichen haben.',
  },
  'user_create_error': <AppLanguage, String>{
    AppLanguage.hr: 'Korisnika nije moguće izraditi.',
    AppLanguage.de: 'Der Benutzer konnte nicht erstellt werden.',
  },
  'user_create_deploy_hint': <AppLanguage, String>{
    AppLanguage.hr:
        'Korisnika nije moguće izraditi. Provjeri je li Cloud Function deployana.',
    AppLanguage.de:
        'Der Benutzer konnte nicht erstellt werden. Prüfe, ob die Cloud Function deployt ist.',
  },
  'user_create_blaze_hint': <AppLanguage, String>{
    AppLanguage.hr:
        'Korisnika nije moguće izraditi dok Firebase projekt nije na Blaze planu i funkcija nije deployana.',
    AppLanguage.de:
        'Der Benutzer kann erst erstellt werden, wenn das Firebase-Projekt auf dem Blaze-Tarif ist und die Funktion deployt wurde.',
  },
  'demo_credentials': <AppLanguage, String>{
    AppLanguage.hr: 'Demo podaci: admin / password ili teren1 / teren123',
    AppLanguage.de: 'Demo-Daten: admin / password oder teren1 / teren123',
  },
  'language_label': <AppLanguage, String>{
    AppLanguage.hr: 'Jezik',
    AppLanguage.de: 'Sprache',
    AppLanguage.en: 'Language',
  },
  'remember_me': <AppLanguage, String>{
    AppLanguage.hr: 'Zapamti me',
    AppLanguage.de: 'Angemeldet bleiben',
    AppLanguage.en: 'Remember me',
  },
  'unlock_saved_login': <AppLanguage, String>{
    AppLanguage.hr: 'Otvori spremljenu prijavu',
    AppLanguage.de: 'Gespeicherte Anmeldung offnen',
    AppLanguage.en: 'Open saved login',
  },
  'unlock_saved_login_subtitle': <AppLanguage, String>{
    AppLanguage.hr: 'Koristi lice, otisak ili šifru uređaja',
    AppLanguage.de: 'Nutze Gesicht, Fingerabdruck oder Geratecode',
    AppLanguage.en: 'Use face, fingerprint or device passcode',
  },
  'biometric_reason': <AppLanguage, String>{
    AppLanguage.hr: 'Potvrdi identitet za učitavanje spremljene prijave.',
    AppLanguage.de:
        'Bitte Identitat bestatigen, um die gespeicherte Anmeldung zu laden.',
  },
  'biometric_error': <AppLanguage, String>{
    AppLanguage.hr: 'Spremljena prijava se nije mogla otvoriti.',
    AppLanguage.de: 'Die gespeicherte Anmeldung konnte nicht geoffnet werden.',
  },
  'welcome': <AppLanguage, String>{
    AppLanguage.hr: 'Dobro došli',
    AppLanguage.de: 'Willkommen',
  },
  'order_goods': <AppLanguage, String>{
    AppLanguage.hr: 'Naruči robu',
    AppLanguage.de: 'Material bestellen',
  },
  'order_goods_subtitle': <AppLanguage, String>{
    AppLanguage.hr: 'Spremi narudžbu za objedinjeno slanje',
    AppLanguage.de: 'Bestellung für gebündelten Versand speichern',
  },
  'project_selection': <AppLanguage, String>{
    AppLanguage.hr: 'Odabir projekta',
    AppLanguage.de: 'Projektauswahl',
  },
  'project_label': <AppLanguage, String>{
    AppLanguage.hr: 'Projekt',
    AppLanguage.de: 'Projekt',
  },
  'project_type': <AppLanguage, String>{
    AppLanguage.hr: 'Tip projekta',
    AppLanguage.de: 'Projekttyp',
  },
  'project_type_construction': <AppLanguage, String>{
    AppLanguage.hr: 'Gradilište',
    AppLanguage.de: 'Baustelle',
  },
  'project_type_production': <AppLanguage, String>{
    AppLanguage.hr: 'Proizvodnja',
    AppLanguage.de: 'Produktion',
  },
  'production_mode_hint': <AppLanguage, String>{
    AppLanguage.hr:
        'Odaberi želiš li ući po stanu ili po zadatku za ovu proizvodnju.',
    AppLanguage.de:
        'Wähle, ob du diese Produktion nach Wohnung oder nach Aufgabe öffnen willst.',
  },
  'choose_by_apartment': <AppLanguage, String>{
    AppLanguage.hr: 'Odaberi stan',
    AppLanguage.de: 'Wohnung wählen',
  },
  'choose_by_task': <AppLanguage, String>{
    AppLanguage.hr: 'Odaberi zadatak',
    AppLanguage.de: 'Aufgabe wählen',
  },
  'select_apartments_for_task': <AppLanguage, String>{
    AppLanguage.hr: 'Označi stanove za odabrani zadatak.',
    AppLanguage.de: 'Wähle die Wohnungen für die ausgewählte Aufgabe aus.',
  },
  'batch_task_completed_message': <AppLanguage, String>{
    AppLanguage.hr: 'Zajednički je potpisano i spremljeno {count} zadataka.',
    AppLanguage.de:
        '{count} Aufgaben wurden gemeinsam unterschrieben und gespeichert.',
  },
  'project_selection_subtitle': <AppLanguage, String>{
    AppLanguage.hr: 'Nastavi na zgrade, stanove i registre',
    AppLanguage.de: 'Weiter zu Gebauden, Wohnungen und Registern',
  },
  'order_title': <AppLanguage, String>{
    AppLanguage.hr: 'Narudžba robe',
    AppLanguage.de: 'Materialbestellung',
  },
  'choose_project_for_order': <AppLanguage, String>{
    AppLanguage.hr: 'Odaberi projekt za narudžbu robe',
    AppLanguage.de: 'Projekt fur die Materialbestellung auswahlen',
  },
  'manager': <AppLanguage, String>{
    AppLanguage.hr: 'Voditelj',
    AppLanguage.de: 'Bauleiter',
  },
  'email': <AppLanguage, String>{
    AppLanguage.hr: 'Email',
    AppLanguage.de: 'E-Mail',
  },
  'choose_building': <AppLanguage, String>{
    AppLanguage.hr: 'Odaberi zgradu',
    AppLanguage.de: 'Gebaude auswahlen',
  },
  'add_order_items': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj stavke za narudžbu',
    AppLanguage.de: 'Bestellpositionen hinzufugen',
  },
  'item_label': <AppLanguage, String>{
    AppLanguage.hr: 'Stavka',
    AppLanguage.de: 'Position',
  },
  'quantity': <AppLanguage, String>{
    AppLanguage.hr: 'Količina',
    AppLanguage.de: 'Menge',
  },
  'remove_item': <AppLanguage, String>{
    AppLanguage.hr: 'Ukloni stavku',
    AppLanguage.de: 'Position entfernen',
  },
  'add_more_item': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj još jednu stavku',
    AppLanguage.de: 'Weitere Position hinzufugen',
  },
  'note': <AppLanguage, String>{
    AppLanguage.hr: 'Napomena',
    AppLanguage.de: 'Notiz',
  },
  'send_order': <AppLanguage, String>{
    AppLanguage.hr: 'Spremi narudžbu',
    AppLanguage.de: 'Bestellung speichern',
  },
  'order_saved_for_batch': <AppLanguage, String>{
    AppLanguage.hr:
        'Narudžba je spremljena. Bit će poslana u zajedničkom mailu u {time}.',
    AppLanguage.de:
        'Die Bestellung wurde gespeichert. Sie wird gesammelt um {time} versendet.',
  },
  'order_cart_title': <AppLanguage, String>{
    AppLanguage.hr: 'Košarica',
    AppLanguage.de: 'Warenkorb',
  },
  'scan_barcode': <AppLanguage, String>{
    AppLanguage.hr: 'Skeniraj barkod',
    AppLanguage.de: 'Barcode scannen',
  },
  'barcode_scanner_title': <AppLanguage, String>{
    AppLanguage.hr: 'Skeniraj artikl',
    AppLanguage.de: 'Artikel scannen',
  },
  'barcode_scanner_hint': <AppLanguage, String>{
    AppLanguage.hr: 'Usmjeri kameru prema barkodu artikla.',
    AppLanguage.de: 'Richte die Kamera auf den Barcode des Artikels.',
  },
  'barcode_not_found': <AppLanguage, String>{
    AppLanguage.hr: 'Nijedan materijal ne odgovara tom barkodu.',
    AppLanguage.de: 'Kein Material passt zu diesem Barcode.',
  },
  'barcode_added_to_cart': <AppLanguage, String>{
    AppLanguage.hr: 'Artikl je dodan u košaricu.',
    AppLanguage.de: 'Artikel wurde dem Warenkorb hinzugefügt.',
  },
  'barcode_scanner_unavailable_web': <AppLanguage, String>{
    AppLanguage.hr: 'Skeniranje barkoda radi samo u mobilnoj aplikaciji.',
    AppLanguage.de: 'Barcode-Scannen funktioniert nur in der mobilen App.',
  },
  'order_cart_empty': <AppLanguage, String>{
    AppLanguage.hr: 'Košarica je prazna.',
    AppLanguage.de: 'Der Warenkorb ist leer.',
  },
  'tap_to_open': <AppLanguage, String>{
    AppLanguage.hr: 'Dodirni za otvaranje',
    AppLanguage.de: 'Zum Öffnen tippen',
  },
  'frequent_items_title': <AppLanguage, String>{
    AppLanguage.hr: 'Često korištene stavke',
    AppLanguage.de: 'Häufig verwendete Artikel',
  },
  'quick_add_title': <AppLanguage, String>{
    AppLanguage.hr: 'Brzo dodavanje',
    AppLanguage.de: 'Schnell hinzufügen',
  },
  'leave_order_title': <AppLanguage, String>{
    AppLanguage.hr: 'Imate stavke u košarici',
    AppLanguage.de: 'Es befinden sich Artikel im Warenkorb',
  },
  'leave_order_message': <AppLanguage, String>{
    AppLanguage.hr: 'Jeste li sigurni da želite napustiti ekran?',
    AppLanguage.de: 'Möchten Sie diesen Bildschirm wirklich verlassen?',
  },
  'select_building_error': <AppLanguage, String>{
    AppLanguage.hr: 'Odaberi zgradu za narudžbu robe.',
    AppLanguage.de: 'Bitte ein Gebaude fur die Bestellung auswahlen.',
  },
  'add_item_error': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj barem jednu stavku i količinu za narudžbu.',
    AppLanguage.de:
        'Bitte mindestens eine Position mit Menge fur die Bestellung eingeben.',
  },
  'project_manager_missing': <AppLanguage, String>{
    AppLanguage.hr: 'Projekt nema upisanog voditelja gradilišta.',
    AppLanguage.de: 'Fur dieses Projekt ist kein Bauleiter eingetragen.',
  },
  'mail_open_error': <AppLanguage, String>{
    AppLanguage.hr: 'Mail aplikacija se nije uspjela otvoriti.',
    AppLanguage.de: 'Die E-Mail-App konnte nicht geoffnet werden.',
  },
  'email_greeting': <AppLanguage, String>{
    AppLanguage.hr: 'Pozdrav,',
    AppLanguage.de: 'Guten Tag,',
  },
  'email_intro': <AppLanguage, String>{
    AppLanguage.hr: 'šaljem narudžbu robe za projekt',
    AppLanguage.de: 'ich sende eine Materialbestellung fur das Projekt',
  },
  'ordered_by': <AppLanguage, String>{
    AppLanguage.hr: 'Naručio korisnik',
    AppLanguage.de: 'Bestellt von',
  },
  'article_number_label': <AppLanguage, String>{
    AppLanguage.hr: 'Artikelnummer',
    AppLanguage.de: 'Artikelnummer',
  },
  'supplier_label': <AppLanguage, String>{
    AppLanguage.hr: 'Dobavljač',
    AppLanguage.de: 'Lieferant',
  },
  'building': <AppLanguage, String>{
    AppLanguage.hr: 'Zgrada',
    AppLanguage.de: 'Gebaude',
  },
  'requested_material': <AppLanguage, String>{
    AppLanguage.hr: 'Traženi materijal',
    AppLanguage.de: 'Benotigtes Material',
  },
  'choose_project': <AppLanguage, String>{
    AppLanguage.hr: 'Dodirni za odabir zgrade',
    AppLanguage.de: 'Tippen fur Gebaudeauswahl',
  },
  'user_label': <AppLanguage, String>{
    AppLanguage.hr: 'Korisnik',
    AppLanguage.de: 'Benutzer',
  },
  'choose_apartment': <AppLanguage, String>{
    AppLanguage.hr: 'Odaberi stan za unos registra',
    AppLanguage.de: 'Wohnung fur den Registereintrag auswahlen',
  },
  'register_entry': <AppLanguage, String>{
    AppLanguage.hr: 'Unos registra',
    AppLanguage.de: 'Registereingabe',
  },
  'enter_register': <AppLanguage, String>{
    AppLanguage.hr: 'Unesi registar',
    AppLanguage.de: 'Register eingeben',
  },
  'continue_checklist': <AppLanguage, String>{
    AppLanguage.hr: 'Nastavi na check listu',
    AppLanguage.de: 'Weiter zur Checkliste',
  },
  'checklist': <AppLanguage, String>{
    AppLanguage.hr: 'Check lista',
    AppLanguage.de: 'Checkliste',
  },
  'register_missing': <AppLanguage, String>{
    AppLanguage.hr: 'Registar nije unesen',
    AppLanguage.de: 'Register wurde nicht eingegeben',
  },
  'register_label': <AppLanguage, String>{
    AppLanguage.hr: 'Registar',
    AppLanguage.de: 'Register',
  },
  'complete_items_error': <AppLanguage, String>{
    AppLanguage.hr: 'Prvo označi sve stavke koje su završene.',
    AppLanguage.de: 'Bitte zuerst alle erledigten Punkte markieren.',
  },
  'go_to_signature': <AppLanguage, String>{
    AppLanguage.hr: 'Završi i idi na potpis',
    AppLanguage.de: 'Abschliessen und zur Unterschrift',
  },
  'photo_docs': <AppLanguage, String>{
    AppLanguage.hr: 'Fotodokumentacija',
    AppLanguage.de: 'Fotodokumentation',
  },
  'photo_instruction': <AppLanguage, String>{
    AppLanguage.hr: 'Prije potpisa označi fotografije koje su napravljene.',
    AppLanguage.de: 'Vor der Unterschrift die aufgenommenen Fotos markieren.',
  },
  'photo_marked': <AppLanguage, String>{
    AppLanguage.hr: 'Fotografija označena',
    AppLanguage.de: 'Foto markiert',
  },
  'photo_compressed': <AppLanguage, String>{
    AppLanguage.hr: 'Fotografija je komprimirana',
    AppLanguage.de: 'Foto wurde komprimiert',
  },
  'add_photo': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj fotografiju',
    AppLanguage.de: 'Foto hinzufugen',
  },
  'retake_photo': <AppLanguage, String>{
    AppLanguage.hr: 'Ponovno fotografiraj',
    AppLanguage.de: 'Foto erneut aufnehmen',
  },
  'remove': <AppLanguage, String>{
    AppLanguage.hr: 'Ukloni',
    AppLanguage.de: 'Entfernen',
  },
  'mark': <AppLanguage, String>{
    AppLanguage.hr: 'Označi',
    AppLanguage.de: 'Markieren',
  },
  'photo_required': <AppLanguage, String>{
    AppLanguage.hr: 'Prvo dodaj barem jednu fotografiju.',
    AppLanguage.de: 'Bitte zuerst mindestens ein Foto hinzufugen.',
  },
  'uploading_photos': <AppLanguage, String>{
    AppLanguage.hr: 'Spremanje fotografija u tijeku...',
    AppLanguage.de: 'Fotos werden gespeichert...',
  },
  'add_extra_photo': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj dodatnu fotografiju',
    AppLanguage.de: 'Zusätzliches Foto hinzufügen',
  },
  'view_photos': <AppLanguage, String>{
    AppLanguage.hr: 'Fotografije',
    AppLanguage.de: 'Fotos',
  },
  'photo_upload_error': <AppLanguage, String>{
    AppLanguage.hr:
        'Fotografije se nisu uspjele spremiti. Provjeri je li Firebase Storage uključen i dopušta li upload.',
    AppLanguage.de:
        'Die Fotos konnten nicht gespeichert werden. Prüfe, ob Firebase Storage aktiviert ist und Uploads erlaubt.',
  },
  'continue_signature': <AppLanguage, String>{
    AppLanguage.hr: 'Nastavi na potpis',
    AppLanguage.de: 'Weiter zur Unterschrift',
  },
  'signature': <AppLanguage, String>{
    AppLanguage.hr: 'Potpis',
    AppLanguage.de: 'Unterschrift',
  },
  'signature_instruction': <AppLanguage, String>{
    AppLanguage.hr: 'Potpišite se unutar polja ispod.',
    AppLanguage.de: 'Bitte im Feld unten unterschreiben.',
  },
  'signature_required': <AppLanguage, String>{
    AppLanguage.hr: 'Potpis je obavezan prije zatvaranja registra.',
    AppLanguage.de:
        'Eine Unterschrift ist vor dem Schliessen des Registers erforderlich.',
  },
  'register_closed': <AppLanguage, String>{
    AppLanguage.hr: 'Registar zatvoren',
    AppLanguage.de: 'Register abgeschlossen',
  },
  'signature_saved_for': <AppLanguage, String>{
    AppLanguage.hr: 'Potpis spremljen za',
    AppLanguage.de: 'Unterschrift gespeichert fur',
  },
  'room': <AppLanguage, String>{
    AppLanguage.hr: 'Prostorija',
    AppLanguage.de: 'Raum',
  },
  'signature_time': <AppLanguage, String>{
    AppLanguage.hr: 'Vrijeme potpisa',
    AppLanguage.de: 'Unterschriftszeit',
  },
  'ok': <AppLanguage, String>{AppLanguage.hr: 'U redu', AppLanguage.de: 'OK'},
  'clear_signature': <AppLanguage, String>{
    AppLanguage.hr: 'Obriši potpis',
    AppLanguage.de: 'Unterschrift loschen',
  },
  'close_register': <AppLanguage, String>{
    AppLanguage.hr: 'Zatvori registar',
    AppLanguage.de: 'Register schliessen',
  },
  'loading': <AppLanguage, String>{
    AppLanguage.hr: 'Učitavanje...',
    AppLanguage.de: 'Wird geladen...',
  },
  'no_data': <AppLanguage, String>{
    AppLanguage.hr: 'Nema podataka.',
    AppLanguage.de: 'Keine Daten vorhanden.',
  },
  'register_already_sent_title': <AppLanguage, String>{
    AppLanguage.hr: 'Check lista je već poslana',
    AppLanguage.de: 'Checkliste wurde bereits gesendet',
  },
  'register_already_sent_message': <AppLanguage, String>{
    AppLanguage.hr:
        'Check lista za ovaj registar je već jednom poslana. Želite li je poslati ponovno?',
    AppLanguage.de:
        'Die Checkliste fur dieses Register wurde bereits gesendet. Mochtest du sie erneut senden?',
  },
  'send_again': <AppLanguage, String>{
    AppLanguage.hr: 'Pošalji ponovno',
    AppLanguage.de: 'Erneut senden',
  },
  'cancel': <AppLanguage, String>{
    AppLanguage.hr: 'Odustani',
    AppLanguage.de: 'Abbrechen',
  },
  'admin_panel': <AppLanguage, String>{
    AppLanguage.hr: 'Admin panel',
    AppLanguage.de: 'Adminbereich',
  },
  'admin_panel_subtitle': <AppLanguage, String>{
    AppLanguage.hr: 'Dodavanje i pregled podataka u bazi',
    AppLanguage.de: 'Daten in der Datenbank verwalten',
  },
  'projects_tab': <AppLanguage, String>{
    AppLanguage.hr: 'Projekti',
    AppLanguage.de: 'Projekte',
  },
  'buildings_tab': <AppLanguage, String>{
    AppLanguage.hr: 'Zgrade',
    AppLanguage.de: 'Gebaude',
  },
  'wohnungs_tab': <AppLanguage, String>{
    AppLanguage.hr: 'Wohnungs',
    AppLanguage.de: 'Wohnungen',
  },
  'materials_tab': <AppLanguage, String>{
    AppLanguage.hr: 'Materijali',
    AppLanguage.de: 'Materialien',
  },
  'users_tab': <AppLanguage, String>{
    AppLanguage.hr: 'Korisnici',
    AppLanguage.de: 'Benutzer',
  },
  'add_project': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj projekt',
    AppLanguage.de: 'Projekt hinzufugen',
  },
  'add_building': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj zgradu',
    AppLanguage.de: 'Gebaude hinzufugen',
  },
  'add_wohnung': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj wohnung',
    AppLanguage.de: 'Wohnung hinzufugen',
  },
  'add_material': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj materijal',
    AppLanguage.de: 'Material hinzufugen',
  },
  'add_user': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj korisnika',
    AppLanguage.de: 'Benutzer hinzufugen',
  },
  'sync_users': <AppLanguage, String>{
    AppLanguage.hr: 'Sinkroniziraj korisnike',
    AppLanguage.de: 'Benutzer synchronisieren',
  },
  'sync_users_success': <AppLanguage, String>{
    AppLanguage.hr: 'Postojeći korisnici su učitani iz Authenticationa.',
    AppLanguage.de: 'Bestehende Benutzer wurden aus Authentication geladen.',
  },
  'document_id': <AppLanguage, String>{
    AppLanguage.hr: 'ID dokumenta',
    AppLanguage.de: 'Dokument-ID',
  },
  'name': <AppLanguage, String>{
    AppLanguage.hr: 'Naziv',
    AppLanguage.de: 'Name',
  },
  'yes': <AppLanguage, String>{AppLanguage.hr: 'Da', AppLanguage.de: 'Ja'},
  'no': <AppLanguage, String>{AppLanguage.hr: 'Ne', AppLanguage.de: 'Nein'},
  'username_label': <AppLanguage, String>{
    AppLanguage.hr: 'Korisničko ime',
    AppLanguage.de: 'Benutzername',
  },
  'full_name_label': <AppLanguage, String>{
    AppLanguage.hr: 'Ime i prezime',
    AppLanguage.de: 'Vor- und Nachname',
  },
  'role_label': <AppLanguage, String>{
    AppLanguage.hr: 'Rola',
    AppLanguage.de: 'Rolle',
  },
  'allowed_projects': <AppLanguage, String>{
    AppLanguage.hr: 'Dozvoljeni projekti (IDs, odvojeni zarezom)',
    AppLanguage.de: 'Erlaubte Projekte (IDs, durch Komma getrennt)',
  },
  'assigned_projects': <AppLanguage, String>{
    AppLanguage.hr: 'Dodijeljeni projekti',
    AppLanguage.de: 'Zugewiesene Projekte',
  },
  'project_task_roles_label': <AppLanguage, String>{
    AppLanguage.hr: 'Vrste posla po projektu',
    AppLanguage.de: 'Arbeitsarten pro Projekt',
  },
  'no_task_roles_available': <AppLanguage, String>{
    AppLanguage.hr: 'Za ovaj projekt još nema učitanih vrsta posla.',
    AppLanguage.de: 'Für dieses Projekt sind noch keine Arbeitsarten geladen.',
  },
  'save': <AppLanguage, String>{
    AppLanguage.hr: 'Spremi',
    AppLanguage.de: 'Speichern',
  },
  'active_label': <AppLanguage, String>{
    AppLanguage.hr: 'Aktivno',
    AppLanguage.de: 'Aktiv',
  },
  'select_project': <AppLanguage, String>{
    AppLanguage.hr: 'Odaberi projekt',
    AppLanguage.de: 'Projekt auswahlen',
  },
  'select_building_admin': <AppLanguage, String>{
    AppLanguage.hr: 'Odaberi zgradu',
    AppLanguage.de: 'Gebaude auswahlen',
  },
  'select_apartment': <AppLanguage, String>{
    AppLanguage.hr: 'Odaberi stan',
    AppLanguage.de: 'Wohnung auswahlen',
  },
  'saved_successfully': <AppLanguage, String>{
    AppLanguage.hr: 'Uspješno spremljeno.',
    AppLanguage.de: 'Erfolgreich gespeichert.',
  },
  'edit': <AppLanguage, String>{
    AppLanguage.hr: 'Uredi',
    AppLanguage.de: 'Bearbeiten',
  },
  'assigned_workers': <AppLanguage, String>{
    AppLanguage.hr: 'Dodijeljeni radnici',
    AppLanguage.de: 'Zugewiesene Mitarbeiter',
  },
  'progress_label': <AppLanguage, String>{
    AppLanguage.hr: 'Dovršenost',
    AppLanguage.de: 'Fortschritt',
  },
  'points_label': <AppLanguage, String>{
    AppLanguage.hr: 'bodova',
    AppLanguage.de: 'Punkte',
  },
  'no_work_tasks_for_apartment': <AppLanguage, String>{
    AppLanguage.hr: 'Za ovaj stan još nema radnih zadataka.',
    AppLanguage.de: 'Für diese Wohnung gibt es noch keine Arbeitsaufgaben.',
  },
  'no_assigned_work_tasks_for_apartment': <AppLanguage, String>{
    AppLanguage.hr:
        'Za ovaj stan nema radnih zadataka dodijeljenih ovom radniku.',
    AppLanguage.de:
        'Für diese Wohnung sind diesem Mitarbeiter keine Arbeitsaufgaben zugewiesen.',
  },
  'open_register': <AppLanguage, String>{
    AppLanguage.hr: 'Otvori registar',
    AppLanguage.de: 'Register öffnen',
  },
  'completed_label': <AppLanguage, String>{
    AppLanguage.hr: 'Završio',
    AppLanguage.de: 'Erledigt von',
  },
  'task_pending': <AppLanguage, String>{
    AppLanguage.hr: 'Čeka izvršenje',
    AppLanguage.de: 'Offen',
  },
  'complete_task': <AppLanguage, String>{
    AppLanguage.hr: 'Označi gotovo',
    AppLanguage.de: 'Als erledigt markieren',
  },
  'complete_task_confirm': <AppLanguage, String>{
    AppLanguage.hr:
        'Jeste li sigurni da želite označiti ovaj zadatak kao gotov?',
    AppLanguage.de:
        'Möchtest du diese Aufgabe wirklich als erledigt markieren?',
  },
  'task_completed_success': <AppLanguage, String>{
    AppLanguage.hr: 'Zadatak je označen kao gotov.',
    AppLanguage.de: 'Die Aufgabe wurde als erledigt markiert.',
  },
  'task_already_completed': <AppLanguage, String>{
    AppLanguage.hr:
        'Ovaj zadatak je već završio drugi radnik i više se ne može ponovno odraditi.',
    AppLanguage.de:
        'Diese Aufgabe wurde bereits von einem anderen Mitarbeiter abgeschlossen und kann nicht erneut erledigt werden.',
  },
  'task_complete_error': <AppLanguage, String>{
    AppLanguage.hr: 'Zadatak se trenutno ne može završiti. Pokušaj ponovno.',
    AppLanguage.de:
        'Die Aufgabe kann momentan nicht abgeschlossen werden. Bitte erneut versuchen.',
  },
  'work_tasks_load_error': <AppLanguage, String>{
    AppLanguage.hr:
        'Radni zadaci za ovaj stan trenutno se nisu učitali kako treba.',
    AppLanguage.de:
        'Die Arbeitsaufgaben für diese Wohnung konnten momentan nicht korrekt geladen werden.',
  },
  'refresh_and_try_again': <AppLanguage, String>{
    AppLanguage.hr: 'Osvježi stranicu i pokušaj ponovno.',
    AppLanguage.de: 'Bitte Seite aktualisieren und erneut versuchen.',
  },
  'saving_signature': <AppLanguage, String>{
    AppLanguage.hr: 'Spremam potpis...',
    AppLanguage.de: 'Unterschrift wird gespeichert...',
  },
  'signature_required_for_task': <AppLanguage, String>{
    AppLanguage.hr: 'Potpis je obavezan prije završetka zadatka.',
    AppLanguage.de:
        'Eine Unterschrift ist erforderlich, bevor die Aufgabe abgeschlossen wird.',
  },
  'inactive': <AppLanguage, String>{
    AppLanguage.hr: 'Neaktivno',
    AppLanguage.de: 'Inaktiv',
  },
  'site_managers_tab': <AppLanguage, String>{
    AppLanguage.hr: 'Voditelji gradilišta',
    AppLanguage.de: 'Bauleiter',
  },
  'add_site_manager': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj voditelja',
    AppLanguage.de: 'Bauleiter hinzufügen',
  },
  'select_site_manager': <AppLanguage, String>{
    AppLanguage.hr: 'Odaberi voditelja gradilišta',
    AppLanguage.de: 'Bauleiter auswählen',
  },
  'register_exports_tab': <AppLanguage, String>{
    AppLanguage.hr: 'Potpisi i izvoz',
    AppLanguage.de: 'Unterschriften und Export',
  },
  'orders_admin_tab': <AppLanguage, String>{
    AppLanguage.hr: 'Narudžbe',
    AppLanguage.de: 'Bestellungen',
  },
  'send_orders_now': <AppLanguage, String>{
    AppLanguage.hr: 'Pošalji sve sada',
    AppLanguage.de: 'Jetzt alles senden',
  },
  'send_orders_now_confirm': <AppLanguage, String>{
    AppLanguage.hr: 'Želite li odmah poslati sve narudžbe na čekanju?',
    AppLanguage.de:
        'Möchtest du alle ausstehenden Bestellungen jetzt sofort senden?',
  },
  'send_orders_now_success': <AppLanguage, String>{
    AppLanguage.hr: 'Narudžbe su poslane odmah.',
    AppLanguage.de: 'Die Bestellungen wurden sofort versendet.',
  },
  'send_orders_now_empty': <AppLanguage, String>{
    AppLanguage.hr: 'Nema narudžbi na čekanju za slanje.',
    AppLanguage.de: 'Es gibt keine ausstehenden Bestellungen zum Senden.',
  },
  'send_orders_now_error': <AppLanguage, String>{
    AppLanguage.hr: 'Narudžbe nije moguće odmah poslati.',
    AppLanguage.de: 'Die Bestellungen konnten nicht sofort gesendet werden.',
  },
  'order_status_pending': <AppLanguage, String>{
    AppLanguage.hr: 'Na čekanju',
    AppLanguage.de: 'Ausstehend',
  },
  'order_status_sent': <AppLanguage, String>{
    AppLanguage.hr: 'Poslano',
    AppLanguage.de: 'Gesendet',
  },
  'all_statuses': <AppLanguage, String>{
    AppLanguage.hr: 'Svi statusi',
    AppLanguage.de: 'Alle Status',
  },
  'scheduled_slot': <AppLanguage, String>{
    AppLanguage.hr: 'Termin slanja',
    AppLanguage.de: 'Versandtermin',
  },
  'no_orders_found': <AppLanguage, String>{
    AppLanguage.hr: 'Još nema spremljenih narudžbi.',
    AppLanguage.de: 'Es gibt noch keine gespeicherten Bestellungen.',
  },
  'status_label': <AppLanguage, String>{
    AppLanguage.hr: 'Status',
    AppLanguage.de: 'Status',
  },
  'created_at_label': <AppLanguage, String>{
    AppLanguage.hr: 'Kreirano',
    AppLanguage.de: 'Erstellt',
  },
  'sent_at_label': <AppLanguage, String>{
    AppLanguage.hr: 'Poslano',
    AppLanguage.de: 'Gesendet',
  },
  'ordered_by_label': <AppLanguage, String>{
    AppLanguage.hr: 'Poslao',
    AppLanguage.de: 'Gesendet von',
  },
  'items_count_label': <AppLanguage, String>{
    AppLanguage.hr: 'Stavki',
    AppLanguage.de: 'Positionen',
  },
  'assign_users_to_project': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj korisnike na projekt',
    AppLanguage.de: 'Benutzer dem Projekt zuweisen',
  },
  'active_workers': <AppLanguage, String>{
    AppLanguage.hr: 'Aktivni radnici',
    AppLanguage.de: 'Aktive Mitarbeiter',
  },
  'no_active_workers': <AppLanguage, String>{
    AppLanguage.hr: 'Nema aktivnih radnika za dodjelu.',
    AppLanguage.de: 'Keine aktiven Mitarbeiter zur Zuweisung vorhanden.',
  },
  'assigned_workers_count': <AppLanguage, String>{
    AppLanguage.hr: 'Dodijeljeno radnika',
    AppLanguage.de: 'Zugewiesene Mitarbeiter',
  },
  'shared_pdf_ready_title': <AppLanguage, String>{
    AppLanguage.hr: 'PDF spreman za dodjelu',
    AppLanguage.de: 'PDF zur Zuordnung bereit',
  },
  'shared_pdf_ready_message': <AppLanguage, String>{
    AppLanguage.hr:
        'Otvorite projekt i stan, pa preko ikone dokumenta spremite podijeljeni PDF.',
    AppLanguage.de:
        'Projekt und Wohnung öffnen und die geteilte PDF über das Dokumentsymbol speichern.',
  },
  'attach_document': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj dokument',
    AppLanguage.de: 'Dokument hinzufügen',
  },
  'add_pdf': <AppLanguage, String>{
    AppLanguage.hr: 'Dodaj PDF',
    AppLanguage.de: 'PDF hinzufügen',
  },
  'apartment_documents': <AppLanguage, String>{
    AppLanguage.hr: 'Dokumenti',
    AppLanguage.de: 'Dokumente',
  },
  'no_documents': <AppLanguage, String>{
    AppLanguage.hr: 'Još nema spremljenih dokumenata.',
    AppLanguage.de: 'Es sind noch keine Dokumente gespeichert.',
  },
  'no_shared_pdfs': <AppLanguage, String>{
    AppLanguage.hr: 'Trenutno nema podijeljenih PDF dokumenata.',
    AppLanguage.de: 'Aktuell sind keine geteilten PDF-Dokumente vorhanden.',
  },
  'save_shared_documents': <AppLanguage, String>{
    AppLanguage.hr: 'Spremi podijeljene dokumente',
    AppLanguage.de: 'Geteilte Dokumente speichern',
  },
  'save_shared_documents_message': <AppLanguage, String>{
    AppLanguage.hr:
        'Odabrani PDF dokumenti spremit će se na ovaj stan i bit će vidljivi u evidenciji.',
    AppLanguage.de:
        'Die ausgewählten PDF-Dokumente werden dieser Wohnung zugeordnet und in der Übersicht gespeichert.',
  },
  'documents_saved_success': <AppLanguage, String>{
    AppLanguage.hr: 'Dokumenti su uspješno spremljeni.',
    AppLanguage.de: 'Die Dokumente wurden erfolgreich gespeichert.',
  },
  'documents_saved_offline': <AppLanguage, String>{
    AppLanguage.hr:
        'Dokumenti su spremljeni na uređaj. Kad se korisnik spoji na internet, bit će poslani na server.',
    AppLanguage.de:
        'Die Dokumente wurden auf dem Gerät gespeichert. Sobald wieder Internet verfügbar ist, werden sie an den Server gesendet.',
  },
  'documents_saved_partial': <AppLanguage, String>{
    AppLanguage.hr:
        'Dio dokumenata je spremljen odmah, a ostali su spremljeni na uređaj i bit će poslani kad se korisnik spoji na internet.',
    AppLanguage.de:
        'Ein Teil der Dokumente wurde sofort gespeichert, die übrigen wurden auf dem Gerät gespeichert und werden gesendet, sobald wieder Internet verfügbar ist.',
  },
  'task_completed_via_import': <AppLanguage, String>{
    AppLanguage.hr: 'Zadatak je označen kao napravljen kroz import.',
    AppLanguage.de: 'Die Aufgabe wurde durch den Import als erledigt markiert.',
  },
  'copy_csv': <AppLanguage, String>{
    AppLanguage.hr: 'Kopiraj CSV',
    AppLanguage.de: 'CSV kopieren',
  },
  'copied_to_clipboard': <AppLanguage, String>{
    AppLanguage.hr: 'CSV je kopiran u međuspremnik.',
    AppLanguage.de: 'CSV wurde in die Zwischenablage kopiert.',
  },
  'signed_by': <AppLanguage, String>{
    AppLanguage.hr: 'Potpisao',
    AppLanguage.de: 'Unterschrieben von',
  },
  'signed_apartment_when': <AppLanguage, String>{
    AppLanguage.hr: 'Kada je koji stan potpisan',
    AppLanguage.de: 'Wann welche Wohnung unterschrieben wurde',
  },
  'search': <AppLanguage, String>{
    AppLanguage.hr: 'Pretraga',
    AppLanguage.de: 'Suche',
  },
  'activate': <AppLanguage, String>{
    AppLanguage.hr: 'Aktiviraj',
    AppLanguage.de: 'Aktivieren',
  },
  'deactivate': <AppLanguage, String>{
    AppLanguage.hr: 'Deaktiviraj',
    AppLanguage.de: 'Deaktivieren',
  },
  'download_excel': <AppLanguage, String>{
    AppLanguage.hr: 'Preuzmi Excel',
    AppLanguage.de: 'Excel herunterladen',
  },
  'export_project_status_tooltip': <AppLanguage, String>{
    AppLanguage.hr: 'Izvezi status projekta',
    AppLanguage.de: 'Projektstatus exportieren',
  },
  'excel_download_ready': <AppLanguage, String>{
    AppLanguage.hr: 'Excel izvoz je pripremljen.',
    AppLanguage.de: 'Der Excel-Export ist fertig.',
  },
  'all_projects': <AppLanguage, String>{
    AppLanguage.hr: 'Svi projekti',
    AppLanguage.de: 'Alle Projekte',
  },
  'all_buildings': <AppLanguage, String>{
    AppLanguage.hr: 'Sve zgrade',
    AppLanguage.de: 'Alle Gebaude',
  },
  'all_workers': <AppLanguage, String>{
    AppLanguage.hr: 'Svi radnici',
    AppLanguage.de: 'Alle Mitarbeiter',
  },
  'all_roles': <AppLanguage, String>{
    AppLanguage.hr: 'Sve uloge',
    AppLanguage.de: 'Alle Rollen',
  },
  'role_worker': <AppLanguage, String>{
    AppLanguage.hr: 'radnik',
    AppLanguage.de: 'Mitarbeiter',
  },
  'role_site_manager': <AppLanguage, String>{
    AppLanguage.hr: 'voditelj gradilišta',
    AppLanguage.de: 'Bauleiter',
  },
  'role_obermonteur': <AppLanguage, String>{
    AppLanguage.hr: 'nadmonter',
    AppLanguage.de: 'Obermonteur',
  },
  'role_admin': <AppLanguage, String>{
    AppLanguage.hr: 'admin',
    AppLanguage.de: 'Admin',
  },
  'sort_by': <AppLanguage, String>{
    AppLanguage.hr: 'Sortiraj po',
    AppLanguage.de: 'Sortieren nach',
  },
  'sort_name_asc': <AppLanguage, String>{
    AppLanguage.hr: 'Naziv A-Z',
    AppLanguage.de: 'Name A-Z',
  },
  'sort_name_desc': <AppLanguage, String>{
    AppLanguage.hr: 'Naziv Z-A',
    AppLanguage.de: 'Name Z-A',
  },
  'sort_created_newest': <AppLanguage, String>{
    AppLanguage.hr: 'Najnovije',
    AppLanguage.de: 'Neueste zuerst',
  },
  'sort_created_oldest': <AppLanguage, String>{
    AppLanguage.hr: 'Najstarije',
    AppLanguage.de: 'Älteste zuerst',
  },
  'sort_updated_newest': <AppLanguage, String>{
    AppLanguage.hr: 'Zadnje uređeno',
    AppLanguage.de: 'Zuletzt bearbeitet',
  },
  'sort_updated_oldest': <AppLanguage, String>{
    AppLanguage.hr: 'Najdulje bez izmjene',
    AppLanguage.de: 'Am längsten unverändert',
  },
  'date_from': <AppLanguage, String>{
    AppLanguage.hr: 'Datum od',
    AppLanguage.de: 'Datum von',
  },
  'date_to': <AppLanguage, String>{
    AppLanguage.hr: 'Datum do',
    AppLanguage.de: 'Datum bis',
  },
  'clear_filters': <AppLanguage, String>{
    AppLanguage.hr: 'Očisti filtere',
    AppLanguage.de: 'Filter zurucksetzen',
  },
  'import': <AppLanguage, String>{
    AppLanguage.hr: 'Import',
    AppLanguage.de: 'Import',
  },
  'import_data': <AppLanguage, String>{
    AppLanguage.hr: 'Import podataka',
    AppLanguage.de: 'Datenimport',
  },
  'import_mode_label': <AppLanguage, String>{
    AppLanguage.hr: 'Način importa',
    AppLanguage.de: 'Importmodus',
  },
  'import_mode_new_project': <AppLanguage, String>{
    AppLanguage.hr: 'Novi projekt',
    AppLanguage.de: 'Neues Projekt',
  },
  'import_mode_sync_project': <AppLanguage, String>{
    AppLanguage.hr: 'Usklada postojećeg projekta',
    AppLanguage.de: 'Bestehendes Projekt abgleichen',
  },
  'select_existing_project': <AppLanguage, String>{
    AppLanguage.hr: 'Odaberi postojeći projekt',
    AppLanguage.de: 'Bestehendes Projekt auswählen',
  },
  'import_sync_hint': <AppLanguage, String>{
    AppLanguage.hr:
        'Kod usklade se koristi odabrani projekt iz aplikacije, a tablica određuje koje zgrade, stanovi i zadaci ostaju aktivni.',
    AppLanguage.de:
        'Beim Abgleich wird das ausgewählte Projekt aus der App verwendet, und die Tabelle bestimmt, welche Gebäude, Wohnungen und Aufgaben aktiv bleiben.',
  },
  'import_structure_hint': <AppLanguage, String>{
    AppLanguage.hr:
        'Učitaj .xlsx radnu tablicu. Listovi su zgrade, red 4 je vrsta posla, red 5 podvrsta, stupac B je stan. Za Register ćelije upiši tip checkliste (Medientrager, Strang ili Strang+Seiten), a ostali poslovi se učitavaju samo gdje je ćelija TRUE ili kvačica.',
    AppLanguage.de:
        'Lade die .xlsx-Arbeitstabelle hoch. Die Blätter sind Gebäude, Zeile 4 ist die Arbeitsart, Zeile 5 die Unterart, Spalte B ist die Wohnung. Für Register-Zellen den Checklisten-Typ eintragen (Medientrager, Strang oder Strang+Seiten), andere Arbeiten werden nur dort importiert, wo TRUE oder ein Häkchen steht.',
  },
  'paste_table': <AppLanguage, String>{
    AppLanguage.hr: 'Zalijepi tablicu',
    AppLanguage.de: 'Tabelle einfügen',
  },
  'import_placeholder': <AppLanguage, String>{
    AppLanguage.hr: 'Projekt 1\tZ1\tWE 1\tmarko;ivan\tMedientrager',
    AppLanguage.de: 'Projekt 1\tZ1\tWE 1\tmarko;ivan\tMedientrager',
  },
  'import_success': <AppLanguage, String>{
    AppLanguage.hr: 'Import je završen.',
    AppLanguage.de: 'Import abgeschlossen.',
  },
  'upload_file': <AppLanguage, String>{
    AppLanguage.hr: 'Učitaj datoteku',
    AppLanguage.de: 'Datei hochladen',
  },
  'download_template': <AppLanguage, String>{
    AppLanguage.hr: 'Preuzmi šprancu',
    AppLanguage.de: 'Vorlage herunterladen',
  },
  'drop_file_here': <AppLanguage, String>{
    AppLanguage.hr: 'Prevuci datoteku ovdje',
    AppLanguage.de: 'Datei hierher ziehen',
  },
  'file_loaded': <AppLanguage, String>{
    AppLanguage.hr: 'Datoteka je učitana u import.',
    AppLanguage.de: 'Datei wurde in den Import geladen.',
  },
  'file_import_not_supported': <AppLanguage, String>{
    AppLanguage.hr: 'Podržan je .xlsx import radne tablice.',
    AppLanguage.de: 'Unterstützt wird der .xlsx-Import der Arbeitstabelle.',
  },
  'import_preview': <AppLanguage, String>{
    AppLanguage.hr: 'Pregled importa',
    AppLanguage.de: 'Importvorschau',
  },
  'selected_file': <AppLanguage, String>{
    AppLanguage.hr: 'Datoteka',
    AppLanguage.de: 'Datei',
  },
  'apartments_label': <AppLanguage, String>{
    AppLanguage.hr: 'Stanovi',
    AppLanguage.de: 'Wohnungen',
  },
  'work_tasks_label': <AppLanguage, String>{
    AppLanguage.hr: 'Radni zadaci',
    AppLanguage.de: 'Arbeitsaufgaben',
  },
  'skipped_entries': <AppLanguage, String>{
    AppLanguage.hr: 'Preskočeno',
    AppLanguage.de: 'Übersprungen',
  },
  'import_permission_denied': <AppLanguage, String>{
    AppLanguage.hr: 'Voditelj gradilišta može uvoziti samo svoje projekte.',
    AppLanguage.de:
        'Der Bauleiter darf nur seine eigenen Projekte importieren.',
  },
  'import_project_required': <AppLanguage, String>{
    AppLanguage.hr: 'Potrebno je odabrati projekt za usklađivanje.',
    AppLanguage.de: 'Für den Abgleich muss ein Projekt ausgewählt werden.',
  },
  'project_material_import_title': <AppLanguage, String>{
    AppLanguage.hr: 'Import materijala za projekt',
    AppLanguage.de: 'Materialimport fur das Projekt',
  },
  'project_material_import_hint': <AppLanguage, String>{
    AppLanguage.hr:
        'Učitaj .xlsx listu materijala samo za ovo gradilište. Globalna lista ostaje netaknuta, a projektna lista zamjenjuje postojeću listu tog projekta.',
    AppLanguage.de:
        'Lade eine .xlsx-Materialliste nur fur diese Baustelle hoch. Die globale Liste bleibt erhalten, die Projektliste ersetzt die bisherige Liste dieses Projekts.',
  },
  'project_material_import_not_supported': <AppLanguage, String>{
    AppLanguage.hr: 'Podržan je samo .xlsx import liste materijala.',
    AppLanguage.de: 'Unterstutzt wird nur der .xlsx-Import der Materialliste.',
  },
  'project_material_import_replace_warning': <AppLanguage, String>{
    AppLanguage.hr:
        'Nova lista će zamijeniti postojeće projektne materijale za ovo gradilište.',
    AppLanguage.de:
        'Die neue Liste ersetzt die bisherigen Projektmaterialien fur diese Baustelle.',
  },
  'project_material_import_success': <AppLanguage, String>{
    AppLanguage.hr: 'Uvezeno je {count} materijala za projekt {project}.',
    AppLanguage.de:
        'Es wurden {count} Materialien fur das Projekt {project} importiert.',
  },
  'import_project_materials_tooltip': <AppLanguage, String>{
    AppLanguage.hr: 'Učitaj materijale za projekt',
    AppLanguage.de: 'Projektmaterialien importieren',
  },
  'categories_label': <AppLanguage, String>{
    AppLanguage.hr: 'Kategorije',
    AppLanguage.de: 'Kategorien',
  },
  'register_saved_offline_title': <AppLanguage, String>{
    AppLanguage.hr: 'Spremljeno offline',
    AppLanguage.de: 'Offline gespeichert',
  },
  'register_saved_offline_message': <AppLanguage, String>{
    AppLanguage.hr:
        'Podaci su spremljeni na uređaj. Kad se korisnik spoji na internet, bit će poslani na server.',
    AppLanguage.de:
        'Die Daten wurden auf dem Gerät gespeichert. Sobald eine Internetverbindung besteht, werden sie an den Server gesendet.',
  },
};

String tr(BuildContext context, String key) {
  final language = LanguageScope.of(context);
  return localizedStrings[key]?[language] ??
      localizedStrings[key]?[AppLanguage.hr] ??
      key;
}

Future<void> loadSavedLanguage() async {
  final prefs = await SharedPreferences.getInstance();
  final savedLanguage = prefs.getString(languagePreferenceKey);

  if (savedLanguage == 'de') {
    languageNotifier.value = AppLanguage.de;
    return;
  }

  if (savedLanguage == 'en') {
    languageNotifier.value = AppLanguage.en;
    return;
  }

  languageNotifier.value = AppLanguage.hr;
}

Future<void> setAppLanguage(AppLanguage language) async {
  languageNotifier.value = language;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(languagePreferenceKey, switch (language) {
    AppLanguage.hr => 'hr',
    AppLanguage.de => 'de',
    AppLanguage.en => 'en',
  });
}
