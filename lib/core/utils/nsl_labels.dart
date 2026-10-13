/// Class index -> Nepali character mapping for the offline NSL classifier.
///
/// Hardcoded on purpose. The training script built its class list with
/// `sorted(set(folder_names))` -- a *string* sort -- so output index does not
/// follow the dataset's numeric folder order: `"10"` sorts before `"2"`, putting
/// folder 10 (ट) at index 2 and folder 2 (ग) at index 12. Deriving this table by
/// numeric order, or from a directory listing with different collation, silently
/// mislabels 34 of the 36 classes while confidences still look healthy. The
/// trailing comment on each entry is its folder number.
class NslLabels {
  NslLabels._();

  /// Chart-style transliteration for showing each model label in the supplied
  /// Nepali finger-spelling chart.
  static const Map<String, String> chartNames = <String, String>{
    'क': 'KA',
    'ख': 'KHA',
    'ग': 'GA',
    'घ': 'GHA',
    'ङ': 'NGA',
    'च': 'CA',
    'छ': 'CHA',
    'ज': 'JA',
    'झ': 'JHA',
    'ञ': 'NYA',
    'ट': 'TA',
    'ठ': 'THA',
    'ड': 'DA',
    'ढ': 'DHA',
    'ण': 'NA',
    'त': 'ta',
    'थ': 'tha',
    'द': 'da',
    'ध': 'dha',
    'न': 'na',
    'प': 'PA',
    'फ': 'PHA',
    'ब': 'BA',
    'भ': 'BHA',
    'म': 'MA',
    'य': 'YA',
    'र': 'RA',
    'ल': 'LA',
    'व': 'WA',
    'श': 'sha',
    'ष': 'SHA',
    'स': 'SA',
    'ह': 'HA',
    'क्ष': 'KSHA',
    'त्र': 'TRA',
    'ज्ञ': 'GYA',
    'श्र': 'SHRA',
  };

  /// Present in the supplied chart but absent from both bundled 36-class
  /// models. It needs labeled examples and a retrained model to be recognized.
  static const String chartOnlyCharacter = 'श्र';

  static String? chartNameFor(String character) => chartNames[character];

  static const List<String> characters = <String>[
    'क', // 0
    'ख', // 1
    'ट', // 10
    'ठ', // 11
    'ड', // 12
    'ढ', // 13
    'ण', // 14
    'त', // 15
    'थ', // 16
    'द', // 17
    'ध', // 18
    'न', // 19
    'ग', // 2
    'प', // 20
    'फ', // 21
    'ब', // 22
    'भ', // 23
    'म', // 24
    'य', // 25
    'र', // 26
    'ल', // 27
    'व', // 28
    'श', // 29
    'घ', // 3
    'ष', // 30
    'स', // 31
    'ह', // 32
    'क्ष', // 33
    'त्र', // 34
    'ज्ञ', // 35
    'ङ', // 4
    'च', // 5
    'छ', // 6
    'ज', // 7
    'झ', // 8
    'ञ', // 9
  ];

  /// Number of classes the model outputs, cross-checked against the model's
  /// output tensor at startup.
  static int get count => characters.length;
}
