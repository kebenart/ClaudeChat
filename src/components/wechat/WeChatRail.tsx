import { MessageCircle, Users, Compass, User } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import WeChatAvatar from './WeChatAvatar';

// MARK: - WeChatRail
//
// Vertical 4-tab rail on the left (≥1024px) that mirrors the macOS app.
// On smaller viewports the parent shell switches this out for `WeChatBottomBar`.
//
// Visual contract:
//   - 64px wide on desktop
//   - active tab gets a subtle green tint background
//   - badge dot/number drawn over the icon for the chat tab (unread count)

export type WeChatTab = 'chats' | 'contacts' | 'discover' | 'me';

interface Props {
  active: WeChatTab;
  onSelect: (tab: WeChatTab) => void;
  unreadCount?: number;
  username?: string;
  onAvatarClick?: () => void;
}

const ICONS: Record<WeChatTab, React.ComponentType<{ className?: string }>> = {
  chats: MessageCircle,
  contacts: Users,
  discover: Compass,
  me: User,
};

export default function WeChatRail({ active, onSelect, unreadCount = 0, username, onAvatarClick }: Props) {
  const { t } = useTranslation('common');
  const tabs: { tab: WeChatTab; label: string }[] = [
    { tab: 'chats', label: t('wechat.tabs.chats', '聊天') },
    { tab: 'contacts', label: t('wechat.tabs.contacts', '通讯录') },
    { tab: 'discover', label: t('wechat.tabs.discover', '发现') },
    { tab: 'me', label: t('wechat.tabs.me', '我') },
  ];

  // Same self seed as the 我 tab + chat bubbles, so all three match.
  const selfSeed = username ? `user-${username}` : 'me';

  return (
    <nav
      className="flex h-full w-16 flex-col items-center border-r border-[var(--wc-border)] bg-[var(--wc-bg-sidebar)] py-9"
      aria-label="WeChat navigation rail"
    >
      <button
        type="button"
        onClick={onAvatarClick}
        className="mb-6 overflow-hidden rounded-md shadow-sm hover:opacity-90"
        title={username ?? 'Me'}
      >
        <WeChatAvatar seed={selfSeed} title={username ?? 'Me'} size={36} />
      </button>

      {tabs.map(({ tab, label }) => {
        const Icon = ICONS[tab];
        const isActive = active === tab;
        const badge = tab === 'chats' ? unreadCount : 0;
        return (
          <button
            key={tab}
            type="button"
            onClick={() => onSelect(tab)}
            className={`relative my-1 flex h-9 w-9 items-center justify-center rounded-md transition-colors ${
              isActive
                ? 'bg-[var(--wc-item-selected)] text-[var(--wc-accent)]'
                : 'text-[var(--wc-text-secondary)] hover:bg-[var(--wc-item-hover)]'
            }`}
            aria-label={label}
            title={label}
          >
            <Icon className="h-5 w-5" />
            {badge > 0 && (
              <span className="absolute -right-1 -top-1 min-w-[16px] rounded-full bg-red-500 px-1 text-center text-[10px] font-medium leading-4 text-white">
                {badge > 99 ? '99+' : badge}
              </span>
            )}
          </button>
        );
      })}
    </nav>
  );
}

// MARK: - Bottom bar (mobile)

type BottomBarProps = Omit<Props, 'onAvatarClick'>;

export function WeChatBottomBar({ active, onSelect, unreadCount = 0 }: BottomBarProps) {
  const { t } = useTranslation('common');
  const tabs: { tab: WeChatTab; label: string }[] = [
    { tab: 'chats', label: t('wechat.tabs.chats', '聊天') },
    { tab: 'contacts', label: t('wechat.tabs.contacts', '通讯录') },
    { tab: 'discover', label: t('wechat.tabs.discover', '发现') },
    { tab: 'me', label: t('wechat.tabs.me', '我') },
  ];

  return (
    <nav
      className="flex w-full items-stretch border-t border-border/50 bg-card pb-safe-area-inset-bottom"
      style={{ minHeight: 'calc(60px + env(safe-area-inset-bottom))' }}
      aria-label="WeChat navigation bar"
    >
      {tabs.map(({ tab, label }) => {
        const Icon = ICONS[tab];
        const isActive = active === tab;
        const badge = tab === 'chats' ? unreadCount : 0;
        return (
          <button
            key={tab}
            type="button"
            onClick={() => onSelect(tab)}
            className={`relative flex flex-1 flex-col items-center justify-center gap-1 py-2 ${
              isActive ? 'text-[var(--wc-accent)]' : 'text-[var(--wc-text-secondary)]'
            }`}
            aria-label={label}
          >
            <Icon className="h-6 w-6" />
            <span className="text-[11px] leading-tight">{label}</span>
            {badge > 0 && (
              <span className="absolute right-[26%] top-1 min-w-[16px] rounded-full bg-red-500 px-1 text-center text-[10px] font-medium leading-4 text-white">
                {badge > 99 ? '99+' : badge}
              </span>
            )}
          </button>
        );
      })}
    </nav>
  );
}
