;;;; -*- Mode: Lisp; indent-tabs-mode: nil -*-

(in-package :hi)

(defvar *all-connections* nil)

(defun list-all-connections ()
  (copy-seq *all-connections*))

(defvar *event-base*)

(defun dispatch-events ()
  (dispatch-events-with-backend *connection-backend*))

(defun dispatch-events-no-hang ()
  (dispatch-events-no-hang-with-backend *connection-backend*))


;;;;
;;;; CONNECTION
;;;;

(defparameter +input-buffer-size+ #x2000)

(defclass connection ()
  ((name :initarg :name
         :accessor connection-name)
   (buffer :initarg :buffer
           :initform nil
           :accessor connection-buffer)
   (stream :initarg :stream
           :initform nil
           :accessor connection-stream)
   (connection-sentinel :initarg :sentinel
                        :initform nil
                        :accessor connection-sentinel)))

(defmethod print-object ((instance connection) stream)
  (print-unreadable-object (instance stream :identity nil :type t)
    (format stream "~A" (connection-name instance))))

(defun make-buffer-with-unique-name (name &rest keys)
  (or (apply #'make-buffer name keys)
      (iter:iter
       (iter:for i from 2)
       (let ((buffer (apply #'make-buffer
                            (format nil "~A<~D>" name i)
                            keys)))
         (when buffer
           (return buffer))))))

(defmethod initialize-instance :after
    ((instance connection) &key buffer)
  (flet ((delete-hook (buffer)
           (when (eq buffer (connection-buffer instance))
             (setf (connection-buffer instance) nil))))
    (typecase buffer
      ((eql t)
       (setf (connection-buffer instance)
             (make-buffer-with-unique-name
              ;; note the space in the buffer name
              (format nil " *Connection ~A*" (connection-name instance))
              :delete-hook (list #'delete-hook))))
      (hi::buffer
       (push #'delete-hook (buffer-delete-hook buffer)))
      (null)
      (t
       (error "expected NIL, T, or a buffer, but found ~A" buffer))))
  (setf (connection-name instance)
        (unique-connection-name (connection-name instance)))
  (push instance *all-connections*))

(defun unique-connection-name (base)
  (let ((name base))
    (iter:iter (iter:for i from 1)
               (iter:while (find name
                                 *all-connections*
                                 :test #'equal
                                 :key #'connection-name))
               (setf name (format nil "~A<~D>" base i)))
    name))

(defun delete-connection-buffer (connection)
  (when (connection-buffer connection)
    (delete-buffer (connection-buffer connection))
    (setf (connection-buffer connection) nil)))

(defmethod delete-connection ((connection connection))
  (delete-connection-buffer connection)
  (setf *all-connections* (remove connection *all-connections*)))

(defun connection-note-event (connection event)
  (let ((sentinel (connection-sentinel connection)))
    (when sentinel
      (funcall sentinel connection event))))


;;;;
;;;; IO-CONNECTION
;;;;

(defparameter +input-buffer-size+ #x2000)

(defclass io-connection (connection)
  ((connection-filter :initarg :filter
                      :initform nil
                      :accessor connection-filter)
   (input-buffer :initform (make-array +input-buffer-size+
                                       :element-type '(unsigned-byte 8))
                 :accessor connection-input-buffer)
   (encoding :initform :utf-8
             :initarg :encoding
             :accessor connection-encoding)))

(defmethod initialize-instance :after
    ((instance io-connection) &key)
  (let ((enc (connection-encoding instance)))
    (when (symbolp enc)
      (setf (connection-encoding instance)
            (babel-encodings:get-character-encoding enc)))))

(defun filter-connection-output (connection data)
  (etypecase data
    (string
     (babel:string-to-octets data :encoding (connection-encoding connection)))
    ((array (unsigned-byte 8) (*))
     data)))

(defun note-connected (connection)
  (connection-note-event connection :connected))

(defun format-to-connection-buffer-or-stream (connection fmt &rest args)
  (let ((buffer (connection-buffer connection))
        (stream (connection-stream connection)))
    (when buffer
      (with-writable-buffer (buffer)
        (insert-string (buffer-point buffer)
                       (apply #'format nil fmt args))))
    (when stream
      (apply #'format stream fmt args))))

(defun insert-into-connection-buffer-or-stream (connection str)
  (let ((buffer (connection-buffer connection))
        (stream (connection-stream connection)))
    (when buffer
      (with-writable-buffer (buffer)
        (insert-string (buffer-point buffer) str)))
    (when stream
      (write-string str stream))))

(defun note-disconnected (connection)
  (connection-note-event connection :disconnected)
  (format-to-connection-buffer-or-stream connection
                                        "~&* Connection ~S disconnected."
                                        connection))

(defun note-error (connection)
  (connection-note-event connection :error)
  (format-to-connection-buffer-or-stream
   connection
   "~&* Error on connection ~S."
   connection))

(defun filter-incoming-data (connection bytes)
  (funcall (or (connection-filter connection) #'default-filter)
           connection
           bytes))

(defun default-filter (connection bytes)
  ;; fixme: what about multibyte characters that got split between two
  ;; input events data?
  (babel:octets-to-string bytes :encoding (connection-encoding connection)))

(defun process-incoming-data (connection)
  (let* ((bytes (%read connection))
         (characters (filter-incoming-data connection bytes))
         (buffer (connection-buffer connection))
         (stream (connection-stream connection)))
    (when (and characters (or buffer stream))
      (insert-into-connection-buffer-or-stream connection characters))))


;;;;
;;;; PROCESS-CONNECTION-MIXIN
;;;;

(defun listify (x)
  (if (listp x) x (list x)))

(defclass process-connection-mixin ()
  ((command :initarg :command
            :accessor connection-command)
   (exit-code :initform nil
              :initarg :exit-code
              :accessor connection-exit-code)
   (exit-status :initform nil
                :initarg :exit-status
                :accessor connection-exit-status)))

(defmethod class-for
    ((backend (eql :iolib)) (type (eql 'process-connection-mixin)))
  'process-connection/iolib)

(defmethod class-for
    ((backend (eql :qt)) (type (eql 'process-connection-mixin)))
  'process-connection/qt)

(defun make-process-connection
    (command &rest args &key name buffer stream filter sentinel)
  (declare (ignore buffer stream filter sentinel))
  (apply #'make-instance
         (class-for *connection-backend* 'process-connection-mixin)
         :name (or name (princ-to-string command))
         :command (listify command)
         args))


;;;;
;;;; TCP-CONNECTION-MIXIN
;;;;

(defclass tcp-connection-mixin ()
  ((host :initarg :host
         :accessor connection-host)
   (port :initarg :port
         :accessor connection-port)))

(defmethod print-object ((instance tcp-connection-mixin) stream)
  (print-unreadable-object (instance stream :identity nil :type t)
    (format stream "~A, connected to ~A:~D"
            (connection-name instance)
            (connection-host instance)
            (connection-port instance))))

(defmethod class-for
    ((backend (eql :iolib)) (type (eql 'tcp-connection-mixin)))
  'tcp-connection/iolib)

(defmethod class-for
    ((backend (eql :qt)) (type (eql 'tcp-connection-mixin)))
  'tcp-connection/qt)

(defun make-tcp-connection
    (name host port &rest args &key buffer stream filter sentinel)
  (declare (ignore buffer stream filter sentinel))
  (apply #'make-instance
         (class-for *connection-backend* 'tcp-connection-mixin)
         :name name
         :host host
         :port port
         args))


;;;;
;;;; FILE-CONNECTION
;;;;

;;; not needed at the moment

#+nil
(progn
  (defclass file-connection (qiodevice-connection)
    ((filename :initarg :filename
               :accessor connection-filename)))

  (defmethod initialize-instance :after ((instance file-connection) &key)
    (let ((socket (#_new QFile (connection-filename instance))))
      (setf (connection-io-device instance) socket)
      (connection-note-event instance :initialized)
      (#_open socket (#_QIODevice::ReadWrite))))

  #+(or)
  (defmethod (setf connection-io-device)
      :after
      (newval (connection file-connection))
    )

  (defun make-file-connection
      (filename &rest args &key name buffer stream filter sentinel)
    (declare (ignore buffer stream filter sentinel))
    (apply #'make-instance
           'file-connection
           :filename filename
           :name (or name filename)
           args)))


;;;;
;;;; PTY-CONNECTION
;;;;

(defun find-a-pty ()
  (block t
    (dolist (char '(#\p #\q) (error "no pty found"))
      (dotimes (digit 16)
        (handler-case
            (open (format nil "/dev/pty~C~X" char digit)
                  :direction :io
                  :if-exists :overwrite)
          (file-error ())
          (:no-error (master-stream)
            (let ((slave-name (format nil "/dev/tty~C~X" char digit)))
              (handler-case
                  (open slave-name
                        :direction :io
                        :if-exists :overwrite)
                (file-error ()
                  (close master-stream))
                (:no-error (slave-stream)
                  (return-from t
                    (values master-stream
                            slave-stream
                            slave-name)))))))))))

(defun make-pty-connection
    (command &key name (buffer nil bufferp) stream)
  (multiple-value-bind (master slave slave-name)
      (find-a-pty)
    (let ((pc
           (make-process-connection
            (format nil "~A ~A~{ ~A~}"
                    "/home/david/clbuild/source/hemlock/c/setpty"
                    slave-name
                    (listify command)))))
      (close slave)
      (%pty-connection-from-stream pc
                                   master
                                   (or name (princ-to-string command))
                                   :buffer (if bufferp
                                               buffer
                                               (null stream))
                                   :stream stream))))

(defclass pty-connection-mixin ()
  ((fd :initarg :descriptor
       :accessor connection-descriptor)
   (process-connection :initarg :process-connection
                       :accessor connection-process-connection)))

(macrolet ((defproxy (name)
             `(defmethod ,name ((connection pty-connection-mixin))
                (,name (connection-process-connection connection)))))
  (defproxy connection-command)
  (defproxy connection-exit-code)
  (defproxy connection-exit-status))

(defmethod delete-connection :before ((connection pty-connection-mixin))
  (delete-connection (connection-process-connection connection)))

(defmethod class-for
    ((backend (eql :iolib)) (type (eql 'pty-connection-mixin)))
  'pty-connection/iolib)

(defmethod class-for
    ((backend (eql :qt)) (type (eql 'pty-connection-mixin)))
  'pty-connection/qt)

(defun %make-pty-connection
    (descriptor
     &rest args
     &key name buffer stream filter sentinel process-connection)
  (declare (ignore buffer stream filter sentinel process-connection))
  (apply #'make-instance
         (class-for *connection-backend* 'pty-connection-mixin)
         :descriptor descriptor
         :name (or name (format nil "descriptor ~D" descriptor))
         :filter (or filter
                     (lambda (connection bytes)
                       (default-filter connection bytes)))
         args))

(defgeneric stream-fd (stream))
(defmethod stream-fd (stream) stream)

#+sbcl
(defmethod stream-fd ((stream sb-sys:fd-stream))
  (sb-sys:fd-stream-fd stream))

#+cmu
(defmethod stream-fd ((stream system:fd-stream))
  (system:fd-stream-fd stream))

#+openmcl
(defmethod stream-fd ((stream ccl::basic-stream))
  (ccl::ioblock-device (ccl::stream-ioblock stream t)))

#+clisp
(defmethod stream-fd ((stream stream))
  ;; sockets appear to be direct instances of STREAM
  (ignore-errors (socket:stream-handles stream)))

(defmethod stream-fd ((stream integer))
  stream)

(defun %pty-connection-from-stream
    (process-connection pty-stream name &key buffer stream filter)
  (%make-pty-connection (stream-fd pty-stream)
                        :process-connection process-connection
                        :name name
                        :filter filter
                        :buffer buffer
                        :stream stream))


;;;;
;;;; LISTENING-CONNECTION
;;;;

(defclass listening-connection (connection)
  ((server :initarg :server
           :initform nil
           :accessor connection-server)
   (acceptor :initarg :acceptor
             :initform nil
             :accessor connection-acceptor)
   (initargs :initarg :initargs
             :initform nil
             :accessor connection-initargs)))

(defgeneric convert-pending-connection (listener))

(defun process-incoming-connection (listener)
  (let ((connection (convert-pending-connection listener)))
    (format-to-connection-buffer-or-stream
     connection "~&* ~A." connection)
    (when (connection-acceptor listener)
      (funcall (connection-acceptor listener) connection))))


;;;;
;;;; TCP-LISTENER-MIXIN
;;;;

(defclass tcp-listener-mixin ()
  ((host :initarg :host
         :accessor connection-host)
   (port :initarg :port
         :accessor connection-port)))

(defmethod initialize-instance :after ((instance tcp-listener-mixin) &key)
  (check-type (connection-host instance) string)
  (check-type (connection-port instance)
              (or null (unsigned-byte 16))))

(defmethod print-object ((instance tcp-listener-mixin) stream)
  (print-unreadable-object (instance stream :identity nil :type t)
    (format stream "~A ~A:~D"
            (connection-name instance)
            (connection-host instance)
            (connection-port instance))))

(defun make-tcp-listener
    (name host port &rest args &key buffer stream acceptor sentinel initargs)
  (declare (ignore buffer stream acceptor sentinel initargs))
  (apply #'make-instance
         (class-for *connection-backend* 'tcp-listener-mixin)
         :name name
         :host host
         :port port
         args))

(defmethod class-for
    ((backend (eql :iolib)) (type (eql 'tcp-listener-mixin)))
  'tcp-listener/iolib)

(defmethod class-for
    ((backend (eql :qt)) (type (eql 'tcp-listener-mixin)))
  'tcp-listener/qt)


;;; wire interaction

(defstruct (connection-device
             (:include hemlock.wire:device)
           (:conc-name "DEVICE-")
           (:constructor %make-connection-device (connection)))
  (connection (error "missing argument") :type connection)
  (reading 0 :type integer)
  (filter-counter 0 :type integer)
  (original-sentinel nil))

(defmethod print-object ((object connection-device) stream)
  (print-unreadable-object (object stream)
    (format stream "~A" (device-connection object))))

(defun make-connection-device (connection)
  (let ((device (%make-connection-device connection)))
    (setf (connection-filter connection)
          (lambda (connection bytes)
            (connection-device-filter device connection bytes)))
    (setf (device-original-sentinel device)
          (connection-sentinel connection))
    (setf (connection-sentinel connection)
          (lambda (connection event)
            (connection-device-sentinel device connection event)))
    device))

(defun connection-device-filter (device connection bytes)
  (declare (ignore connection))
  (setf bytes (copy-seq bytes))
  (later
   (incf (device-filter-counter device))
   (hemlock.wire:device-append-to-input-buffer device bytes)
   (when (zerop (device-reading device))
     (hemlock.wire:device-serve-requests device t)))
  nil)

(defun connection-device-sentinel (device connection event)
  (when (device-original-sentinel device)
    (funcall (device-original-sentinel device) connection event))
  ;; fixme: anything else to do here?
  )

(defmethod hemlock.wire:device-listen
    ((device connection-device))
  (connection-listen (device-connection device)))

(defmethod hemlock.wire:device-write
    ((device connection-device) buffer &optional (end (length buffer)))
  (connection-write (subseq buffer 0 end) (device-connection device)))

(defmethod hemlock.wire:device-read
    ((device connection-device) buffer)
  (declare (ignore buffer))
  (unwind-protect
       (let ((previous-counter (device-filter-counter device)))
         (incf (device-reading device))
         (iter:iter (iter:while (eql previous-counter (device-filter-counter device)))
                    (dispatch-events)))
    (decf (device-reading device)))
  0)
