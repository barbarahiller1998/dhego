import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String languagePreferenceKey = 'selected_language';

final ValueNotifier<AppLanguage> languageNotifier = ValueNotifier<AppLanguage>(
  AppLanguage.hr,
);

enum AppLanguage { hr, de }

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
  },
  'login_title': <AppLanguage, String>{
    AppLanguage.hr: 'Prijava',
    AppLanguage.de: 'Anmeldung',
  },
  'username': <AppLanguage, String>{
    AppLanguage.hr: 'Korisničko ime',
    AppLanguage.de: 'Benutzername',
  },
  'username_or_email': <AppLanguage, String>{
    AppLanguage.hr: 'Korisničko ime ili e-mail',
    AppLanguage.de: 'Benutzername oder E-Mail',
  },
  'password': <AppLanguage, String>{
    AppLanguage.hr: 'Lozinka',
    AppLanguage.de: 'Passwort',
  },
  'login_button': <AppLanguage, String>{
    AppLanguage.hr: 'Prijavi se',
    AppLanguage.de: 'Anmelden',
  },
  'login_error': <AppLanguage, String>{
    AppLanguage.hr: 'Pogrešno korisničko ime ili lozinka.',
    AppLanguage.de: 'Falscher Benutzername oder falsches Passwort.',
  },
  'inactive_user_error': <AppLanguage, String>{
    AppLanguage.hr: 'Korisnički račun nije aktivan.',
    AppLanguage.de: 'Das Benutzerkonto ist nicht aktiv.',
  },
  'forgot_password': <AppLanguage, String>{
    AppLanguage.hr: 'Zaboravljena lozinka?',
    AppLanguage.de: 'Passwort vergessen?',
  },
  'password_reset_sent': <AppLanguage, String>{
    AppLanguage.hr: 'Poslan je e-mail za promjenu lozinke.',
    AppLanguage.de: 'Die E-Mail zum Zurücksetzen des Passworts wurde gesendet.',
  },
  'password_reset_error': <AppLanguage, String>{
    AppLanguage.hr: 'Nije moguće poslati e-mail za promjenu lozinke.',
    AppLanguage.de:
        'Die E-Mail zum Zurücksetzen des Passworts konnte nicht gesendet werden.',
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
  },
  'remember_me': <AppLanguage, String>{
    AppLanguage.hr: 'Zapamti me',
    AppLanguage.de: 'Angemeldet bleiben',
  },
  'unlock_saved_login': <AppLanguage, String>{
    AppLanguage.hr: 'Otvori spremljenu prijavu',
    AppLanguage.de: 'Gespeicherte Anmeldung offnen',
  },
  'unlock_saved_login_subtitle': <AppLanguage, String>{
    AppLanguage.hr: 'Koristi lice, otisak ili šifru uređaja',
    AppLanguage.de: 'Nutze Gesicht, Fingerabdruck oder Geratecode',
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
    AppLanguage.hr: 'Pošalji narudžbu voditelju gradilišta',
    AppLanguage.de: 'Bestellung an den Bauleiter senden',
  },
  'project_selection': <AppLanguage, String>{
    AppLanguage.hr: 'Odabir projekta',
    AppLanguage.de: 'Projektauswahl',
  },
  'project_label': <AppLanguage, String>{
    AppLanguage.hr: 'Projekt',
    AppLanguage.de: 'Projekt',
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
    AppLanguage.hr: 'Pošalji narudžbu mailom',
    AppLanguage.de: 'Bestellung per E-Mail senden',
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
  'document_id': <AppLanguage, String>{
    AppLanguage.hr: 'ID dokumenta',
    AppLanguage.de: 'Dokument-ID',
  },
  'name': <AppLanguage, String>{
    AppLanguage.hr: 'Naziv',
    AppLanguage.de: 'Name',
  },
  'username_label': <AppLanguage, String>{
    AppLanguage.hr: 'Korisničko ime',
    AppLanguage.de: 'Benutzername',
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
  'import_structure_hint': <AppLanguage, String>{
    AppLanguage.hr:
        'Zalijepi retke iz Excela ili LibreOfficea u stupcima: projekt, zgrada, stan, radnici, tip checkliste. Radnike odvoji znakom ;, a tip neka bude Medientrager, Strang ili Strang+Seiten.',
    AppLanguage.de:
        'Zeilen aus Excel oder LibreOffice in den Spalten Projekt, Gebäude, Wohnung, Mitarbeiter, Checklisten-Typ einfügen. Mitarbeiter mit ; trennen. Für den Typ Medientrager, Strang oder Strang+Seiten verwenden.',
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
    AppLanguage.hr:
        'Podržani su .xlsx i .csv. Za .ods koristi copy/paste iz tablice.',
    AppLanguage.de:
        'Unterstützt werden .xlsx und .csv. Für .ods bitte Tabelle kopieren und einfügen.',
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
  return localizedStrings[key]?[language] ?? key;
}

Future<void> loadSavedLanguage() async {
  final prefs = await SharedPreferences.getInstance();
  final savedLanguage = prefs.getString(languagePreferenceKey);

  if (savedLanguage == 'de') {
    languageNotifier.value = AppLanguage.de;
    return;
  }

  languageNotifier.value = AppLanguage.hr;
}

Future<void> setAppLanguage(AppLanguage language) async {
  languageNotifier.value = language;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    languagePreferenceKey,
    language == AppLanguage.de ? 'de' : 'hr',
  );
}

