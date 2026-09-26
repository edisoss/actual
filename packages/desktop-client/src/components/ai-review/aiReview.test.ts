import { hasAiReviewTag, removeAiReviewTag } from './aiReview';

describe('hasAiReviewTag', () => {
  it('finds the tag on its own or among other text', () => {
    expect(hasAiReviewTag('#ai-review')).toBe(true);
    expect(hasAiReviewTag('Lunch #ai-review')).toBe(true);
    expect(hasAiReviewTag('#ai-review #work lunch')).toBe(true);
  });

  it('ignores missing notes and look-alike tags', () => {
    expect(hasAiReviewTag(null)).toBe(false);
    expect(hasAiReviewTag(undefined)).toBe(false);
    expect(hasAiReviewTag('')).toBe(false);
    expect(hasAiReviewTag('#ai-reviewed')).toBe(false);
    expect(hasAiReviewTag('x#ai-review')).toBe(false);
  });

  it('gives the same answer when called repeatedly', () => {
    expect(hasAiReviewTag('#ai-review')).toBe(true);
    expect(hasAiReviewTag('#ai-review')).toBe(true);
  });
});

describe('removeAiReviewTag', () => {
  it('removes the tag and keeps the rest of the note', () => {
    expect(removeAiReviewTag('#ai-review')).toBe('');
    expect(removeAiReviewTag('Lunch #ai-review')).toBe('Lunch');
    expect(removeAiReviewTag('#ai-review Lunch')).toBe('Lunch');
    expect(removeAiReviewTag('Lunch #ai-review #work')).toBe('Lunch #work');
  });

  it('leaves notes without the tag unchanged', () => {
    expect(removeAiReviewTag('Lunch #ai-reviewed')).toBe('Lunch #ai-reviewed');
    expect(removeAiReviewTag(null)).toBe('');
  });
});
