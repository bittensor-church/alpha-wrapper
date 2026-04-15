export default function TxModal({ isOpen, title, message, onClose }) {
  if (!isOpen) return null;

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="spinner" />
        <h3>{title || 'Processing...'}</h3>
        <p>{message || 'Please confirm in MetaMask'}</p>
        {onClose && (
          <button className="btn btn-ghost btn-sm" onClick={onClose}>
            Close
          </button>
        )}
      </div>
    </div>
  );
}
