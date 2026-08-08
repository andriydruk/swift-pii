#!/usr/bin/env python3
"""Generate a language's differential corpus from its `*_core_news_sm` model.

Same method as the English ones: give spaCy the raw text, record what it
produced, and let the Swift side try to reproduce it from the same input. What
is compared is tokens with offsets and NORMs, fine-grained tags, coarse POS,
lemmas, and entity spans.

The corpus has two halves, for two different reasons.

**Harvested from spaCy's own tests for that language.** Those files are where
the tokenizer's edge cases already live -- German guillemets and 40-character
compounds, Spanish inverted question marks, Italian elisions like `dell'` --
and the people who wrote them knew which cases were sharp. Extracted by AST
rather than regex so it survives reformatting.

**Written for this port.** Prose containing what a PII pipeline actually meets:
names with titles, cities, companies with legal forms, dates in the local order,
currency with comma decimals, and abbreviations that end in a period without
ending a sentence. Those abbreviations are tokenizer exceptions, and getting one
wrong shifts every offset after it.

The text is an *input*, not an assertion: it does not need to be interesting
prose, it needs to be prose that both implementations see identically.

    python3 Tools/language_reference.py \\
        --python <venv python with spacy + the model> \\
        --lang de --out Tests/PresidioConformance/Fixtures/de_gold.json
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import subprocess
import sys

# --- The written half -------------------------------------------------------
# Kept here rather than in a data file so that regenerating the corpus is one
# command, and so the reason each group exists can be written next to it.

PROSE = {"de": [
    # Names, titles, and the abbreviation-period problem.
    "Dr. Anna Müller arbeitet seit 2019 bei der Siemens AG in München.",
    "Herr Schmidt und Frau Dr. Weber haben den Vertrag am 3. März unterschrieben.",
    "Prof. Dr. Hans-Jürgen Schäfer lehrt an der Universität Heidelberg.",
    "Der Patient, Herr Klaus Böhm, wurde am 14.02.1978 in Dresden geboren.",
    "Frau Özdemir leitet die Abteilung seit dem 1. Januar.",
    "Sehr geehrte Frau Dr. Krüger, vielen Dank für Ihre Nachricht vom 12. Mai.",
    # Organisations and legal forms.
    "Die Deutsche Bahn AG betreibt den Fernverkehr zwischen Hamburg und Berlin.",
    "Die Müller & Söhne GmbH & Co. KG hat ihren Sitz in Stuttgart.",
    "Volkswagen, BMW und Daimler sind in Wolfsburg, München bzw. Stuttgart ansässig.",
    "Das Bundesamt für Sicherheit in der Informationstechnik warnt vor der Lücke.",
    # Places.
    "Von Köln nach Düsseldorf fährt man etwa 40 Minuten.",
    "Die Zugspitze liegt an der Grenze zwischen Bayern und Tirol.",
    "Er zog von Leipzig über Frankfurt am Main nach Zürich.",
    "Das Treffen findet in Sankt Augustin bei Bonn statt.",
    # Contact details, which is what the recognizers are for.
    "Sie erreichen mich unter anna.mueller@example.de oder +49 30 901820.",
    "Meine Telefonnummer lautet 089 12345678, mobil 0170 1234567.",
    "Die Rechnung geht an buchhaltung@beispiel-firma.de.",
    "Bitte überweisen Sie auf DE89 3704 0044 0532 0130 00.",
    "Die Steuer-ID lautet 65929970489 und die Steuernummer 181/815/08155.",
    "Der Server ist unter 192.168.0.14 erreichbar, die Doku unter https://intern.example.de/hilfe.",
    # Dates, numbers, currency, ordinals -- all tokenizer-sensitive.
    "Am 31.12.2023 um 23:59 Uhr endete die Frist.",
    "Der Betrag von 1.234,56 EUR wurde am 5. Juni gebucht.",
    "Im 3. Quartal stieg der Umsatz um 12,5 Prozent.",
    "Die Sitzung dauerte von 9.30 bis 17.00 Uhr.",
    "Er wurde am 2. Oktober 1990 geboren, also kurz vor der Wiedervereinigung.",
    # Abbreviations that do not end a sentence.
    "Das gilt z.B. für Verträge, die vor 2020 geschlossen wurden.",
    "Bitte bringen Sie Ihren Ausweis, Ihre Karte usw. mit.",
    "Die Adresse lautet Hauptstr. 12, 10115 Berlin.",
    "Vgl. dazu Nr. 4 der Anlage bzw. § 12 Abs. 3 BGB.",
    "Die Lieferung erfolgt ca. 3 Werktage nach Zahlungseingang.",
    # Compounds, umlauts, ß, hyphenation.
    "Die Rindfleischetikettierungsüberwachungsaufgabenübertragungsgesetz-Debatte war lang.",
    "Der Straßenbahnhaltestellenfahrplan hängt am Bahnhof.",
    "Die Kraftfahrzeug-Haftpflichtversicherung ist gesetzlich vorgeschrieben.",
    "Größere Maßnahmen müssen schriftlich beschlossen werden.",
    "Süß-sauer schmeckt die Soße überraschend gut.",
    # Quotation styles German actually uses.
    "»Wer hat das entschieden?«, fragte sie.",
    "„Das war nicht abgesprochen“, sagte der Abteilungsleiter.",
    'Er nannte es ein "Missverständnis" und ging.',
    # Sentence shapes that stress the sentence-independent tokenizer.
    "Und dann? Nichts.",
    "Ja!!! Wirklich???",
    "Er sagte: Das ist erledigt.",
    "(Siehe Anhang.) Weitere Angaben folgen.",
    "E-Mail, Telefon o. Ä. sind anzugeben.",
],

"es": [
    # Names and the titles that end in a period without ending a sentence.
    "El Dr. Juan Pérez atiende los martes en el Hospital La Paz.",
    "La Sra. García firmó el contrato el 3 de marzo de 2021.",
    "D. Alberto Ruiz-Gallardón presentó el informe en Madrid.",
    "La paciente, Dña. María Fernández, nació el 14/02/1978 en Sevilla.",
    "Atentamente, Lic. Rodríguez, Departamento de Recursos Humanos.",
    # Organisations and legal forms.
    "Telefónica S.A. y el Banco Santander firmaron el acuerdo en Barcelona.",
    "Inditex, con sede en Arteixo, factura más que sus competidores.",
    "La empresa Construcciones Álvarez S.L. presentó su concurso de acreedores.",
    "El Ministerio de Hacienda publicó la resolución en el BOE.",
    # Places.
    "Viajó de Bilbao a Valencia pasando por Zaragoza.",
    "La sede está en A Coruña, aunque el registro figura en Las Palmas.",
    "El Camino de Santiago termina en Santiago de Compostela.",
    # Contact details.
    "Puede escribirme a ana.lopez@ejemplo.es o llamar al +34 612 345 678.",
    "Mi teléfono es el 91 123 45 67 y el móvil el 600 112 233.",
    "El servidor responde en 192.168.0.14 y la documentación está en https://ejemplo.es/ayuda.",
    "Su NIF es 20899533P y el NIE de su esposa X1234567L.",
    "Transfiera el importe a ES91 2100 0418 4502 0005 1332.",
    # Dates, numbers, currency.
    "El plazo terminó el 31/12/2023 a las 23:59 horas.",
    "El importe de 1.234,56 EUR se abonó el 5 de junio.",
    "En el tercer trimestre las ventas subieron un 12,5 por ciento.",
    "La reunión será de 9.30 a 17.00.",
    # Abbreviations, which is where Spanish tokenizer exceptions live.
    "Esto se aplica p.ej. a los contratos anteriores a 2020.",
    "Traiga su DNI, la tarjeta, etc. a la cita.",
    "La dirección es c/ Mayor, núm. 12, 28013 Madrid.",
    "Vid. el art. 12 del Reglamento, apdo. 3.",
    "Aprox. tres días hábiles después del pago.",
    # Inverted punctuation, accents, ñ, elisions.
    "¿Quién tomó esa decisión?",
    "¡No estaba acordado!, dijo el jefe de área.",
    "El niño añadió que mañana traería la señal.",
    "¿Cómo? ¿Cuándo? Nadie lo sabía.",
    "Sí, aunque aún faltan más datos.",
    # Clitics and contractions, which the lemmatizer cares about.
    "Dáselo al director cuando venga.",
    "Vamos al cine del centro.",
    "Quiero decírtelo antes de que se entere.",
],

"it": [
    # Names and titles.
    "Il Dott. Marco Rossi riceve il martedì presso l'ospedale di Milano.",
    "La Sig.ra Bianchi ha firmato il contratto il 3 marzo 2021.",
    "Il Prof. Giuseppe De Luca insegna all'Università di Bologna.",
    "Il paziente, Sig. Luca Ferrari, è nato il 14/02/1978 a Napoli.",
    "Gentile Dott.ssa Conti, la ringrazio per la Sua comunicazione.",
    # Organisations.
    "Enel S.p.A. e Intesa Sanpaolo hanno firmato l'accordo a Roma.",
    "La Ferrari ha sede a Maranello, in provincia di Modena.",
    "La società Costruzioni Verdi S.r.l. ha presentato il bilancio.",
    "Il Ministero dell'Economia ha pubblicato il decreto.",
    # Places.
    "È andato da Torino a Palermo passando per Firenze.",
    "La sede legale è a Reggio nell'Emilia.",
    "Il Monte Bianco si trova al confine tra Italia e Francia.",
    # Contact details.
    "Può scrivermi a anna.russo@esempio.it oppure chiamare il +39 06 1234567.",
    "Il mio numero è 02 12345678, il cellulare 320 1234567.",
    "Il server risponde su 192.168.0.14 e la documentazione è su https://esempio.it/aiuto.",
    "Il suo codice fiscale è RSSMRA85M01H501Z.",
    "Effettui il bonifico su IT60 X054 2811 1010 0000 0123 456.",
    # Dates, numbers, currency.
    "Il termine è scaduto il 31/12/2023 alle 23:59.",
    "L'importo di 1.234,56 EUR è stato accreditato il 5 giugno.",
    "Nel terzo trimestre le vendite sono salite del 12,5 per cento.",
    "La riunione si terrà dalle 9.30 alle 17.00.",
    # Abbreviations.
    "Questo vale ad es. per i contratti anteriori al 2020.",
    "Porti la carta d'identità, la tessera, ecc. all'appuntamento.",
    "L'indirizzo è via Roma, n. 12, 20121 Milano.",
    "Cfr. l'art. 12 del Regolamento, comma 3.",
    "Circa tre giorni lavorativi dopo il pagamento.",
    # Elisions and apostrophes, which drive Italian tokenization.
    "L'azienda dell'ingegnere è un'impresa nuova.",
    "Un'altra volta gliel'ho detto chiaramente.",
    "Nell'ambito dell'accordo, l'80% è già stato versato.",
    "Dopo l'incontro all'aeroporto, se n'è andato.",
    # Accents and elided verbs.
    "Perché non è più così semplice?",
    "Sì, però ne parliamo dopo.",
    "Qual è la città più vicina?",
],

"ru": [
    # Names, patronymics, and the titles that abbreviate with a period.
    "Д-р Анна Петровна Смирнова принимает по вторникам в больнице №5.",
    "Иван Сергеевич Кузнецов подписал договор 3 марта 2021 года.",
    "Проф. Владимир Ильич Ковалёв читает лекции в МГУ.",
    "Пациент, Алексей Николаевич Морозов, родился 14.02.1978 в Новосибирске.",
    "Уважаемая Мария Ивановна, благодарю Вас за письмо от 12 мая.",
    # Organisations.
    "ПАО «Газпром» и ОАО «РЖД» подписали соглашение в Москве.",
    "Компания ООО «Ромашка» зарегистрирована в Санкт-Петербурге.",
    "Яндекс и Сбербанк объявили о совместном проекте.",
    "Министерство финансов опубликовало постановление.",
    # Places.
    "Из Екатеринбурга в Казань поезд идёт примерно сутки.",
    "Он переехал из Владивостока через Иркутск в Нижний Новгород.",
    "Встреча состоится в Ростове-на-Дону.",
    # Contact details.
    "Напишите мне на anna.smirnova@example.ru или позвоните +7 495 123-45-67.",
    "Мой телефон 8 (812) 555-11-22, мобильный 8-900-123-45-67.",
    "Сервер доступен по адресу 192.168.0.14, документация — https://example.ru/help.",
    "Переведите сумму на счёт RU02 0445 2560 0407 0281 0412 3456 7890 1.",
    # Dates, numbers, currency.
    "Срок истёк 31.12.2023 в 23:59.",
    "Сумма 1 234,56 руб. была зачислена 5 июня.",
    "В третьем квартале продажи выросли на 12,5 процента.",
    "Совещание продлится с 9.30 до 17.00.",
    # Abbreviations that do not end a sentence.
    "Это касается напр. договоров, заключённых до 2020 года.",
    "Возьмите паспорт, карту и т.д. на приём.",
    "Адрес: ул. Ленина, д. 12, кв. 3, 190000 Санкт-Петербург.",
    "См. ст. 12 Регламента, п. 3.",
    "Примерно три рабочих дня после оплаты.",
    # Quotation styles and punctuation Russian actually uses.
    "«Кто это решил?» — спросила она.",
    "— Это не обсуждалось, — сказал начальник отдела.",
    "Что? Ничего.",
    "Да!!! Правда???",
    # Ё, hyphenation, case.
    "Всё-таки ещё раз перечитайте объём работ.",
    "Кто-нибудь когда-нибудь это проверял?",
    "Северо-западный ветер усилился.",
],

"uk": [
    # Names and titles.
    "Д-р Оксана Петрівна Коваленко приймає у вівторок у лікарні №5.",
    "Іван Сергійович Шевченко підписав договір 3 березня 2021 року.",
    "Проф. Володимир Ілліч Бондаренко читає лекції в КНУ.",
    "Пацієнт, Олексій Миколайович Мороз, народився 14.02.1978 у Львові.",
    "Шановна Маріє Іванівно, дякую Вам за лист від 12 травня.",
    # Organisations.
    "ПАТ «Укрзалізниця» та АТ «Ощадбанк» підписали угоду в Києві.",
    "Компанія ТОВ «Ромашка» зареєстрована в Одесі.",
    "Міністерство фінансів оприлюднило постанову.",
    # Places.
    "З Харкова до Дніпра потяг їде близько шести годин.",
    "Він переїхав із Ужгорода через Вінницю до Запоріжжя.",
    "Зустріч відбудеться в Кам'янці-Подільському.",
    # Contact details.
    "Напишіть мені на oksana.kovalenko@example.ua або телефонуйте +380 44 123 45 67.",
    "Мій телефон 044 555 11 22, мобільний 067 123 45 67.",
    "Сервер доступний за адресою 192.168.0.14, документація — https://example.ua/dopomoga.",
    # Dates, numbers, currency.
    "Строк минув 31.12.2023 о 23:59.",
    "Сума 1 234,56 грн. була зарахована 5 червня.",
    "У третьому кварталі продажі зросли на 12,5 відсотка.",
    "Нарада триватиме з 9.30 до 17.00.",
    # Abbreviations.
    "Це стосується напр. договорів, укладених до 2020 року.",
    "Візьміть паспорт, картку тощо на прийом.",
    "Адреса: вул. Хрещатик, буд. 12, кв. 3, 01001 Київ.",
    "Див. ст. 12 Регламенту, п. 3.",
    # Apostrophes, which Ukrainian uses inside words -- the case most likely
    # to be tokenized wrongly by rules written for another language.
    "П'ять об'єктів було з'єднано в одну систему.",
    "Прем'єр-міністр виступив із заявою.",
    "Він з'ясував, що м'ясо було зіпсоване.",
    # Quotation styles and punctuation.
    "«Хто це вирішив?» — запитала вона.",
    "— Це не обговорювалося, — сказав начальник відділу.",
    "Що? Нічого.",
    # Ї, є, і, ґ and hyphenation.
    "Її ім'я є в списку, ґанок відремонтували торік.",
    "Будь-хто коли-небудь це перевіряв?",
    "Північно-західний вітер посилився.",
],

"fr": [
    # Names and titles.
    "Le Dr Jean Dupont reçoit le mardi à l'hôpital Saint-Louis.",
    "Mme Marie Lefèvre a signé le contrat le 3 mars 2021.",
    "M. Pierre-Yves Le Gall enseigne à l'université de Lyon.",
    "Le patient, M. Luc Moreau, est né le 14/02/1978 à Bordeaux.",
    "Madame la Directrice, je vous remercie de votre courrier du 12 mai.",
    # Organisations.
    "La société Renault SA et BNP Paribas ont signé l'accord à Paris.",
    "L'entreprise Dupont & Fils SARL a son siège à Nantes.",
    "Le ministère de l'Économie a publié le décret.",
    # Places.
    "Il est allé de Strasbourg à Marseille en passant par Dijon.",
    "Le siège social est à Aix-en-Provence.",
    "Le mont Blanc se situe à la frontière franco-italienne.",
    # Contact details.
    "Vous pouvez m'écrire à anne.martin@exemple.fr ou appeler le +33 1 42 68 53 00.",
    "Mon numéro est le 01 42 68 53 00, le portable 06 12 34 56 78.",
    "Le serveur répond sur 192.168.0.14 et la documentation est sur https://exemple.fr/aide.",
    "Effectuez le virement sur FR14 2004 1010 0505 0001 3M02 606.",
    # Dates, numbers, currency.
    "Le délai a expiré le 31/12/2023 à 23h59.",
    "Le montant de 1 234,56 EUR a été crédité le 5 juin.",
    "Au troisième trimestre, les ventes ont augmenté de 12,5 pour cent.",
    "La réunion se tiendra de 9h30 à 17h00.",
    # Abbreviations.
    "Cela vaut p. ex. pour les contrats antérieurs à 2020.",
    "Apportez votre carte d'identité, la carte vitale, etc. au rendez-vous.",
    "L'adresse est 12, rue de la République, 75011 Paris.",
    "Cf. l'art. 12 du Règlement, al. 3.",
    # Elision and the apostrophe, which drives French tokenization.
    "L'entreprise de l'ingénieur est aujourd'hui fermée.",
    "Qu'est-ce qu'il a dit ? Je n'en sais rien.",
    "J'ai vu l'homme dont je t'ai parlé.",
    "C'est-à-dire qu'aucune décision n'a été prise.",
    # Hyphenated inversions and accents.
    "Peut-être viendra-t-il demain ?",
    "Où est-elle allée après-midi ?",
    "Ça va très bien, merci — et vous ?",
    "« Qui a décidé cela ? », demanda-t-elle.",
],

"pt": [
    # Names and titles.
    "O Dr. João Silva atende às terças no hospital de Lisboa.",
    "A Sra. Maria Santos assinou o contrato em 3 de março de 2021.",
    "O Prof. António Ferreira leciona na Universidade de Coimbra.",
    "O paciente, Sr. Luís Oliveira, nasceu em 14/02/1978 no Porto.",
    "Exma. Sra. Doutora, agradeço a sua carta de 12 de maio.",
    # Organisations.
    "A Petrobras e o Banco do Brasil assinaram o acordo em Brasília.",
    "A empresa Construções Almeida Lda. tem sede em Braga.",
    "O Ministério da Fazenda publicou a portaria.",
    # Places.
    "Foi de Belo Horizonte a Salvador passando por Vitória.",
    "A sede fica em São Paulo, mas o registo é no Rio de Janeiro.",
    "Florianópolis e Curitiba ficam no Sul do país.",
    # Contact details.
    "Escreva-me para ana.souza@exemplo.com.br ou ligue para +55 11 91234-5678.",
    "O meu telefone é (11) 3123-4567 e o telemóvel 912 345 678.",
    "O servidor responde em 192.168.0.14 e a documentação está em https://exemplo.pt/ajuda.",
    "O CPF dele é 123.456.789-09 e o CNPJ da empresa 11.222.333/0001-81.",
    # Dates, numbers, currency.
    "O prazo terminou em 31/12/2023 às 23:59.",
    "O valor de 1.234,56 EUR foi creditado a 5 de junho.",
    "No terceiro trimestre as vendas subiram 12,5 por cento.",
    "A reunião decorrerá das 9.30 às 17.00.",
    # Abbreviations.
    "Isto aplica-se p. ex. aos contratos anteriores a 2020.",
    "Traga o bilhete de identidade, o cartão, etc. à consulta.",
    "A morada é Rua Augusta, n.º 12, 1100-053 Lisboa.",
    "Cf. o art. 12.º do Regulamento, n.º 3.",
    # Clitic hyphens, which are the Portuguese tokenizer's distinguishing case.
    "Diga-me quando puder, e avise-o também.",
    "Encontrámo-nos ontem e falámos disso.",
    "Dar-lhe-ei uma resposta amanhã.",
    # Contractions, tildes and cedillas.
    "Vamos ao cinema do centro, à noite.",
    "As informações estão na secção seguinte.",
    "Não é assim tão simples, pois não?",
    "Ele é o irmão mais novo — não o mais velho.",
],
}


CHILD = r"""
import json, sys
import spacy

texts = json.loads(sys.argv[1])
model = sys.argv[2]

nlp = spacy.load(model)

cases = []
for text in texts:
    doc = nlp(text)
    cases.append({
        "text": text,
        "tokens": [
            {"text": t.text, "offset": t.idx, "norm": t.norm_,
             "tag": t.tag_, "pos": t.pos_, "lemma": t.lemma_,
             # spaCy forbids entities from spanning a sentence boundary, and
             # takes boundaries from the parser. Recorded so the Swift side can
             # be measured both with and without them.
             "sent_start": bool(t.is_sent_start)}
            for t in doc
        ],
        "entities": [
            {"label": e.label_, "start": e.start_char, "end": e.end_char,
             "text": e.text}
            for e in doc.ents
        ],
    })

meta = nlp.meta
json.dump({
    "model": f"{meta['lang']}_{meta['name']}-{meta['version']}",
    "spacy_version": spacy.__version__,
    "cases": cases,
}, sys.stdout, ensure_ascii=False)
"""


def harvest_spacy_tests(python: str, lang: str) -> list[str]:
    """Pull every string literal out of spaCy's tests for one language.

    By AST, so a reformat or a new parametrize case is picked up without
    touching this script. Literals that are obviously not German text -- import
    fragments, single characters, fixture names -- are dropped by length.
    """
    finder = (
        f"import os, spacy.tests.lang.{lang} as m; "
        "print(os.path.dirname(m.__file__))"
    )
    proc = subprocess.run([python, "-c", finder], capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"WARN: spaCy {lang} tests not found; skipping harvest", file=sys.stderr)
        return []

    directory = proc.stdout.strip()
    texts: list[str] = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".py"):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as fh:
            try:
                tree = ast.parse(fh.read())
            except SyntaxError:
                continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                value = node.value.strip()
                # Docstrings and fixture identifiers are not corpus material.
                if len(value) < 4 or "\n" in value and len(value) < 40:
                    continue
                if value.isidentifier():
                    continue
                texts.append(value)
    return texts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True, help="interpreter with spacy + the model")
    ap.add_argument("--lang", required=True, choices=sorted(PROSE), help="language code")
    ap.add_argument("--model", default=None, help="defaults to <lang>_core_news_sm")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    model = args.model or f"{args.lang}_core_news_sm"
    prose = PROSE[args.lang]
    harvested = harvest_spacy_tests(args.python, args.lang)
    # Deduplicate while keeping order, so the corpus is stable across runs.
    seen: set[str] = set()
    texts: list[str] = []
    for text in prose + harvested:
        if text not in seen:
            seen.add(text)
            texts.append(text)

    proc = subprocess.run(
        [args.python, "-c", CHILD, json.dumps(texts), model],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        return proc.returncode

    payload = json.loads(proc.stdout)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    tokens = sum(len(c["tokens"]) for c in payload["cases"])
    entities = sum(len(c["entities"]) for c in payload["cases"])
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  model      {payload['model']} (spaCy {payload['spacy_version']})")
    print(f"  texts      {len(payload['cases'])} "
          f"({len(prose)} written, {len(texts) - len(prose)} harvested)")
    print(f"  tokens     {tokens}")
    print(f"  entities   {entities}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
