import { WorkoutPageError } from './workout-page-validation';

// Deliberately narrow local rules. Avoid broad exercise-language matches such as
// "killer workout", "deadlift", "snatch", "clean", "assault bike", or "chest".
// Reports and uploader blocks cover context-dependent abuse this filter cannot infer.
const prohibitedText = [
  /\b(?:niggers?|faggots?|kikes?)\b/i,
  /\b(?:i|we)\s+(?:(?:am|are)\s+going\s+to\s+|will\s+)(?:kill|murder|rape)\s+(?:you|him|her|them)\b/i,
  /\b(?:kill|murder|rape)\s+(?:yourself|yourselves)\b/i,
  /\bchild\s*(?:porn(?:ography)?|sexual\s+(?:abuse|images?|videos?))\b/i,
  /\bsend\s+(?:me\s+)?nudes\b/i,
  /\b(?:porn(?:ographic)?\s+(?:videos?|images?|clips?)|fuck\s+(?:you|me|her|him))\b/i,
];

export function validateSharedText(title: string, description: string, additionalTerms: string[] = []): void {
  const text = `${title}\n${description}`.normalize('NFKC').replace(/[\u200b-\u200d\ufeff]/g, '').toLowerCase();
  if (prohibitedText.some(pattern => pattern.test(text)) || additionalTerms.slice(0, 100).some(term => {
    const normalized = term.normalize('NFKC').trim().toLowerCase();
    return normalized.length >= 3 && normalized.length <= 120 && text.includes(normalized);
  })) throw new WorkoutPageError(400, 'Please edit the shared title or description before uploading', 'CONTENT_NOT_ALLOWED');
}
