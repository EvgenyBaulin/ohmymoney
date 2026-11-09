import CoreKit
import Foundation

extension Lifestyle {
  /// Display data for starter-set selection; provisional translations carry explicit metadata.
  public func translation(language: String) -> StarterTranslation {
    let language = StarterLanguage(identifier: language)
    let names = Self.translations[language] ?? Self.translations[.en] ?? [:]
    return StarterTranslation(
      text: names[self] ?? rawValue, verification: language.translationVerification)
  }

  static let translations: [StarterLanguage: [Lifestyle: String]] = rows.mapValues { row in
    Dictionary(
      uniqueKeysWithValues: zip(Lifestyle.allCases, row.split(separator: "|").map(String.init)))
  }

  private static let rows: [StarterLanguage: String] = [
    .en: "Student|Employed|Freelance|Family|Living alone|Living with a partner|With children",
    .ru: "Студент|Работаю по найму|Фриланс|Семья|Живу один|Живу с партнёром|Есть дети",
    .uk: "Студент|Працюю за наймом|Фриланс|Сім'я|Живу сам|Живу з партнером|Є діти",
    .be: "Студэнт|Працую па найме|Фрыланс|Сям'я|Жыву адзін|Жыву з партнёрам|Ёсць дзеці",
    .kk: "Студент|Жалдамалы жұмыс|Фриланс|Отбасы|Жалғыз тұрамын|Серіктеспен тұрамын|Балаларым бар",
    .uz: "Talaba|Yollanma ish|Frilans|Oila|Yolgʻiz yashayman|Juftim bilan yashayman|Bolalarim bor",
    .ky:
      "Студент|Жалданып иштейм|Фриланс|Үй-бүлө|Жалгыз жашайм|Өнөктөшүм менен жашайм|Балдарым бар",
    .tg:
      "Донишҷӯ|Корманди кироя|Фриланс|Оила|Танҳо зиндагӣ мекунам|Бо шарик зиндагӣ мекунам|Фарзанд дорам",
    .hy:
      "Ուսանող|Վարձու աշխատող|Անկախ աշխատող|Ընտանիք|Ապրում եմ մենակ|Ապրում եմ զուգընկերոջ հետ|Ունեմ երեխաներ",
    .ka:
      "სტუდენტი|დაქირავებით ვმუშაობ|ფრილანსი|ოჯახი|მარტო ვცხოვრობ|პარტნიორთან ვცხოვრობ|მყავს შვილები",
    .az: "Tələbə|Muzdlu işçi|Frilans|Ailə|Tək yaşayıram|Tərəfdaşımla yaşayıram|Uşaqlarım var",
    .de: "Studium|Angestellt|Freiberuflich|Familie|Alleinlebend|Mit Partner|Mit Kindern",
    .fr: "Étudiant|Salarié|Indépendant|Famille|Vie en solo|Vie en couple|Avec enfants",
    .es: "Estudiante|Empleado|Autónomo|Familia|Vivo solo|Vivo en pareja|Con hijos",
    .it: "Studente|Dipendente|Libero professionista|Famiglia|Vivo da solo|Vivo in coppia|Con figli",
    .portuguesePortugal:
      "Estudante|Trabalhador por conta de outrem|Independente|Família|Vivo sozinho|Vivo em casal|Com filhos",
    .pl: "Student|Pracownik|Freelancer|Rodzina|Mieszkam sam|Mieszkam z partnerem|Mam dzieci",
    .cs: "Student|Zaměstnanec|Na volné noze|Rodina|Bydlím sám|Bydlím s partnerem|Mám děti",
    .nl: "Student|In loondienst|Zelfstandig|Familie|Alleenwonend|Met partner|Met kinderen",
    .tr:
      "Öğrenci|Ücretli çalışan|Serbest çalışan|Aile|Yalnız yaşıyorum|Partnerimle yaşıyorum|Çocuklarım var",
    .chineseSimplified: "学生|雇员|自由职业|家庭|独居|与伴侣同住|有孩子",
    .chineseTraditional: "學生|受僱工作|自由工作|家庭|獨居|與伴侶同住|有孩子",
    .ja: "学生|会社員|フリーランス|家族|一人暮らし|パートナーと同居|子どもがいる",
    .ko: "학생|직장인|프리랜서|가족|혼자 거주|파트너와 거주|자녀 있음",
    .vi: "Sinh viên|Nhân viên|Tự do|Gia đình|Sống một mình|Sống cùng bạn đời|Có con",
    .id:
      "Mahasiswa|Karyawan|Pekerja lepas|Keluarga|Tinggal sendiri|Tinggal bersama pasangan|Punya anak",
    .th: "นักศึกษา|พนักงาน|ฟรีแลนซ์|ครอบครัว|อยู่คนเดียว|อยู่กับคู่รัก|มีลูก",
    .hi: "छात्र|नौकरीपेशा|फ़्रीलांस|परिवार|अकेले रहते हैं|साथी के साथ रहते हैं|बच्चे हैं",
    .portugueseBrazil:
      "Estudante|Empregado|Autônomo|Família|Moro sozinho|Moro com parceiro|Tenho filhos",
    .ar: "طالب|موظف|عمل حر|عائلة|أعيش وحدي|أعيش مع شريك|لدي أطفال",
    .he: "סטודנט|שכיר|עצמאי|משפחה|גר לבד|גר עם בן זוג|עם ילדים",
  ]
}
