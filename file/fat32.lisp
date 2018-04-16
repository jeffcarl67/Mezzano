;;;; Copyright (c) 2017-2018 Bruno Cichon <ebrasca@librepanther.com>
;;;; This code is licensed under the MIT license.
;;;; For now support reading fat32 FS and some write operations.

(defpackage :mezzano.fat32-file-system
  (:use :cl :mezzano.file-system)
  (:export)
  (:import-from :sys.int
                #:explode))

(in-package :mezzano.fat32-file-system)

(defstruct fat32
  (boot-jmp nil)
  (oem-name nil :type string)
  (bytes-per-sector nil :type (unsigned-byte 16))
  (sectors-per-cluster nil :type (unsigned-byte 8))
  (reserved-sector-count nil :type (unsigned-byte 16))
  (table-count nil :type (unsigned-byte 8))
  (root-entry-count nil :type (unsigned-byte 16))
  (total-sectors16 nil :type (unsigned-byte 16))
  (media-type nil :type (unsigned-byte 8))
  (table-size-16 nil :type (unsigned-byte 16))
  (sectors-per-track nil :type (unsigned-byte 16))
  (head-side-count nil :type (unsigned-byte 16))
  (hidden-sector-count nil :type (unsigned-byte 32))
  (total-sectors32 nil :type (unsigned-byte 32))
  ;;fat32
  (table-size-32 nil :type (unsigned-byte 32))
  (extended-flags nil)
  (fat-version nil)
  (root-cluster nil :type (unsigned-byte 32))
  (fat-info nil :type (unsigned-byte 16))
  (backup-BS-sector nil :type (unsigned-byte 16))
  (reserved-0 nil)
  (drive-number nil :type (unsigned-byte 8))
  (reserved-1 nil)
  (boot-signature nil :type (unsigned-byte 8))
  (volume-id nil :type (unsigned-byte 32))
  (volume-label nil :type string)
  (fat-type-label nil :type string)
  (bc nil) ; 90 420
  (bps nil :type (unsigned-byte 32)))

(defconstant +bootable-partition-signature+ #xAA55)

(defun check-boot-jmp (boot-jmp)
  (let ((n0 (aref boot-jmp 0))
        (n2 (aref boot-jmp 2)))
    (if (or (and (= n0 #xEB)
                 (= n2 #x90))
            (= n0 #xE9))
        boot-jmp
        (error "Bad boot-jmp : ~a .
Valid forms are : #(#xEB x #x90) and #(#xE9 x x).
X is for some 1 byte number." boot-jmp))))

(defun check-bytes-per-sector (bytes-per-sector)
  "Ensure that bytes-per-sector is valid."
  (loop :for n :in '(512 1024 2048 4096)
        :do (when (= n bytes-per-sector)
              (return bytes-per-sector))
        :finally (error "Bad bytes-per-sector : ~a .
Valid bytes-per-sector are 512, 1024, 2048 and 4096" bytes-per-sector)))

(defun check-sectors-per-cluster (sectors-per-cluster bytes-per-sector)
  (loop :for n :in '(1 2 4 8 16 32 64 128)
        :do (when (= n sectors-per-cluster)
              (return sectors-per-cluster))
        :finally (error "Bad sectors-per-cluster : ~a .
Valid bytes-per-sector are 1,2,4,8,16,32,64,128" sectors-per-cluster))
  (when (> (* sectors-per-cluster bytes-per-sector)
           32768)
    (error "Error sectors-per-cluster * bytes-per-sector > 32KiB .
sectors-per-cluster= ~a bytes-per-sector= ~a" sectors-per-cluster bytes-per-sector))
  sectors-per-cluster)

(defun check-media-type (media-type)
  (loop :for n :in '(#xF0 #xF8 #xF9 #xFA #xFB #xFC #xFD #xFE #xFF)
        :do (when (= n media-type)
              (return media-type))
        :finally (error "Bad media-type : ~a .
Valid media-type ara #xF0 #xF8 #xF9 #xFA #xFB #xFC #xFD #xFE #xFF" media-type)))

(defun check-fat-type-label32 (fat-type-label)
  (if (string= "FAT32   " fat-type-label)
      fat-type-label
      (error "Bad fat-type-label : ~a .
Valid media-type ara 'FAT32   ' " fat-type-label)))

(defun check-bps (bps)
  (unless (= bps +bootable-partition-signature+)
    (error "Bad bps : ~a .
Valid bps are ~a" bps +bootable-partition-signature+))
  bps)

(defun read-fat32-structure (disk)
  (let* ((sector (read-sector disk 0 1))
         (boot-jmp (subseq sector 0 3))
         (bytes-per-sector (sys.int::ub16ref/le sector 11))
         (sectors-per-cluster (aref sector 13))
         (table-count (aref sector 16))
         (root-entry-count (sys.int::ub16ref/le sector 17))
         (total-sectors16 (sys.int::ub16ref/le sector 19))
         (media-type (aref sector 21))
         (table-size-16 (sys.int::ub16ref/le sector 22))
         (total-sectors32 (sys.int::ub32ref/le sector 32))
         (fat-type-label (map 'string #'code-char (subseq sector 82 90)))
         (bps (sys.int::ub16ref/le sector 510)))
    (check-boot-jmp boot-jmp)
    (check-bytes-per-sector bytes-per-sector)
    (check-sectors-per-cluster sectors-per-cluster bytes-per-sector)
    (assert (>= table-count 1))
    (assert (= 0 root-entry-count))
    (assert (= 0 total-sectors16))
    (check-media-type media-type)
    (assert (= table-size-16 0))
    (assert (not (zerop total-sectors32)))
    (check-fat-type-label32 fat-type-label)
    (check-bps bps)
    (values
     (make-fat32
      :boot-jmp boot-jmp
      :oem-name (map 'string #'code-char (subseq sector 3 11))
      :bytes-per-sector bytes-per-sector
      :sectors-per-cluster sectors-per-cluster
      :reserved-sector-count (sys.int::ub16ref/le sector 14)
      :table-count table-count
      :root-entry-count root-entry-count
      :total-sectors16 total-sectors16
      :media-type media-type
      :table-size-16 table-size-16
      :sectors-per-track (sys.int::ub16ref/le sector 24)
      :head-side-count (sys.int::ub16ref/le sector 26)
      :hidden-sector-count (sys.int::ub32ref/le sector 28)
      :total-sectors32 total-sectors32
      :table-size-32 (sys.int::ub32ref/le sector 36)
      :extended-flags (sys.int::ub16ref/le sector 40)
      ;; high byte is major revision number and low byte is minor revision number
      :fat-version (sys.int::ub16ref/le sector 42)
      :root-cluster (sys.int::ub32ref/le sector 44)
      :fat-info (sys.int::ub16ref/le sector 48)
      :backup-BS-sector (sys.int::ub16ref/le sector 50)
      :reserved-0 (logior (ash (sys.int::ub32ref/le sector 60) 64)
                          (sys.int::ub64ref/le sector 52))
      :drive-number (aref sector 64) ; Operating system specific
      :reserved-1 (aref sector 65)
      :boot-signature (aref sector 66)
      :volume-id (sys.int::ub32ref/le sector 67)
      :volume-label (map 'string #'code-char (subseq sector 71 82))
      :fat-type-label fat-type-label
      :bc nil
      :bps bps))))

(defstruct fs-info
  (lead-signature nil :type (unsigned-byte 32))
  (reserved-0 nil) ; 4 480
  (structure-signature nil :type (unsigned-byte 32))
  (last-free-cluster nil :type (unsigned-byte 32))
  (next-free-cluster nil :type (unsigned-byte 32))
  (reserved-1 nil) ; 496 12
  (trail-signature nil :type (unsigned-byte 32)))

(defconstant +lead-signature+ #x41615252)
(defconstant +structure-signature+ #x61417272)
(defconstant +trail-signature+ #xAA550000)

(defun check-lead-signature (lead-signature)
  (if (= lead-signature +lead-signature+)
      lead-signature
      (error "Bad lead-signature : ~a .
Valid lead-signature is ~a" lead-signature +lead-signature+)))

(defun check-structure-signature (structure-signature)
  (if (= structure-signature +structure-signature+)
      structure-signature
      (error "Bad structure-signature : ~a .
Valid structure-signature is ~a" structure-signature +structure-signature+)))

(defun check-trail-signature (trail-signature)
  (if (= trail-signature +trail-signature+)
      trail-signature
      (error "Bad trail-signature : ~a .
Valid trail-signature is ~a" trail-signature +trail-signature+)))

(defun read-fat32-info-structure (disk fat32)
  (let* ((sector (read-sector disk (fat32-fat-info fat32) 1))
         (lead-signature (sys.int::ub32ref/le sector 0))
         (structure-signature (sys.int::ub32ref/le sector 484))
         (trail-signature (sys.int::ub32ref/le sector 508)))
    (check-lead-signature lead-signature)
    (check-structure-signature structure-signature)
    (check-trail-signature trail-signature)
    (make-fs-info
     :lead-signature lead-signature
     :reserved-0 nil
     :structure-signature structure-signature
     :last-free-cluster (sys.int::ub32ref/le sector 488)
     :next-free-cluster (sys.int::ub32ref/le sector 492)
     :reserved-1 nil
     :trail-signature trail-signature)))

(defun write-fat32-info-structure (disk fat32 fat32-info)
  (let ((sector (make-array (fat32-bytes-per-sector fat32)
                            :area :wired :element-type '(unsigned-byte 8))))
    (setf (sys.int::ub32ref/le sector 0) (fs-info-lead-signature fat32-info)
          (sys.int::ub32ref/le sector 484) (fs-info-structure-signature fat32-info)
          (sys.int::ub32ref/le sector 488) (fs-info-last-free-cluster fat32-info)
          (sys.int::ub32ref/le sector 492) (fs-info-next-free-cluster fat32-info)
          (sys.int::ub32ref/le sector 508) (fs-info-trail-signature fat32-info))
    (write-sector disk
                  (fat32-fat-info fat32)
                  sector
                  1)))

(defun read-fat (disk fat32)
  (read-sector disk
               (fat32-reserved-sector-count fat32)
               (/ (fat32-table-size-32 fat32)
                  (fat32-table-count fat32))))

(defun write-fat (disk fat32 fat)
  (write-sector disk
                (fat32-reserved-sector-count fat32)
                fat
                (/ (fat32-table-size-32 fat32)
                   (fat32-table-count fat32))))

(defun root-dir-sectors ()
  0)

(defun data-sectors (fat32)
  (- (fat32-total-sectors32 fat32)
     (+ (fat32-reserved-sector-count fat32)
        (* (fat32-table-count fat32)
           (fat32-table-size-32 fat32))
        (root-dir-sectors))))

(defun total-clusters (fat32)
  (floor
   (/ (data-sectors fat32)
      (fat32-sectors-per-cluster fat32))))

(defun first-data-sector (fat32)
  (+ (fat32-reserved-sector-count fat32)
     (* (fat32-table-count fat32)
        (fat32-table-size-32 fat32))
     (root-dir-sectors)))

(defun first-root-dir-sector (fat32)
  (- (first-data-sector fat32)
     (root-dir-sectors)))

(defun first-sector-of-cluster (fat32 cluster-offset)
  (+ (* (- cluster-offset 2)
        (fat32-sectors-per-cluster fat32))
     (first-data-sector fat32)))

(defun bytes-per-cluster (fat32)
  (* (fat32-sectors-per-cluster fat32)
     (fat32-bytes-per-sector fat32)))

(defun next-free-cluster (fat)
  (loop :for i :from 0 :by 4 :to (1- (array-dimension fat 0))
        :for m := (sys.int::ub32ref/le fat i)
        :when (zerop m)
        :return (ash i -2)))

(defun get-fat32-time ()
  "Return time and date in fat32 format"
  (multiple-value-bind (second minute hour date month year) (get-decoded-time)
    (values (logior (ash second -1)
                    (ash minute 5)
                    (ash hour 11))
            (logior date
                    (ash month 5)
                    (ash (- year 1980) 9)))))

(defun read-sector (disk start-sector n-sectors)
  "Read n sectors from disk"
  (let* ((sector-size (mezzano.supervisor:disk-sector-size disk))
         (result (make-array (* sector-size  n-sectors) :element-type '(unsigned-byte 8)))
         (temp-buf (make-array sector-size :element-type '(unsigned-byte 8) :area :wired)))
    (dotimes (offset n-sectors)
      (multiple-value-bind (successp error-reason)
          (mezzano.supervisor:disk-read disk (+ start-sector offset) 1 temp-buf)
        (when (not successp)
          (error "Disk read error: ~S" error-reason)))
      (replace result temp-buf :start1 (* offset sector-size)))
    result))

(defun write-sector (disk start-sector array n-sectors)
  "Write n sectors to disk"
  (let* ((sector-size (mezzano.supervisor:disk-sector-size disk))
         (temp-buf (make-array sector-size :element-type '(unsigned-byte 8) :area :wired)))
    (dotimes (offset n-sectors)
      (replace temp-buf array :start2 (* offset sector-size))
      (multiple-value-bind (successp error-reason)
          (mezzano.supervisor:disk-write disk (+ start-sector offset) 1 temp-buf)
        (when (not successp)
          (error "Disk write error: ~S" error-reason))))))

;;; bit offsets
(defconstant +attribute-read-only+ 0)
(defconstant +attribute-hidden+ 1)
(defconstant +attribute-system+ 2)
(defconstant +attribute-volume-id+ 3)
(defconstant +attribute-directory+ 4)
(defconstant +attribute-archive+ 5)

(defun file-p (directory offset)
  (= (ldb (byte 1 +attribute-archive+)
          (aref directory (+ 11 offset)))
     1))

(defun directory-p (directory offset)
  (= (ldb (byte 1 +attribute-directory+)
          (aref directory (+ 11 offset)))
     1))

(defun read-file (fat32 disk start-cluster fat)
  (let* ((spc (fat32-sectors-per-cluster fat32))
         (n-clusters (do ((cluster-n start-cluster
                                     (sys.int::ub32ref/le fat (* cluster-n 4)))
                          (cluster-count 0 (1+ cluster-count)))
                         ((>= cluster-n #x0FFFFFF8) cluster-count)))
         (sector-size (mezzano.supervisor:disk-sector-size disk))
         (result (make-array (* sector-size spc n-clusters) :element-type '(unsigned-byte 8)))
         (temp-buf (make-array (* spc sector-size) :element-type '(unsigned-byte 8) :area :wired)))
    (do ((cluster-n start-cluster (sys.int::ub32ref/le fat (* cluster-n 4)))
         (n-cluster 0 (1+ n-cluster)))
        ((>= cluster-n #x0FFFFFF8) result)
      (mezzano.supervisor:disk-read disk (first-sector-of-cluster fat32 cluster-n) spc temp-buf)
      (replace result temp-buf :start1 (* n-cluster spc sector-size)))))

;; TODO Add posibility to resize file
;; TODO Don't rewrite unchanged clusters.
(defun write-file (fat32 disk start-cluster fat array)
  (let* ((spc (fat32-sectors-per-cluster fat32))
         (sector-size (mezzano.supervisor:disk-sector-size disk))
         (temp-buf (make-array (* spc sector-size) :element-type '(unsigned-byte 8) :area :wired)))
    (do ((cluster-n start-cluster (sys.int::ub32ref/le fat (* cluster-n 4)))
         (n-cluster 0 (1+ n-cluster)))
        ((>= cluster-n #x0FFFFFF8) t)
      (replace temp-buf array :start2 (* n-cluster spc sector-size))
      (mezzano.supervisor:disk-write disk (first-sector-of-cluster fat32 cluster-n) spc temp-buf))))

(defun read-first-cluster (directory offset)
  (logior (ash (sys.int::ub16ref/le directory (+ 20 offset)) 16)
          (ash (sys.int::ub16ref/le directory (+ 26 offset)) 0)))

(defun read-file-size (directory offset)
  (sys.int::ub32ref/le directory (+ 28 offset)))

(defun checksum (array offset)
  "Return checksum of sort name"
  (loop :with sum := 0
        :for i :from offset :to (+ 10 offset)
        :for octet := (aref array i)
        :do (setf sum
                  (ldb (byte 8 0)
                       (+ (ash sum -1)
                          (ash (logand sum 1) 7) ; rotate
                          octet))) ; add next name byte
        :finally (return sum)))

(defun next-file (directory offset)
  (do ((i offset (+ 32 i)))
      ((<= (length directory) i) nil)
    (let ((first-byte (aref directory i)))
      (when (zerop first-byte)
        (return))
      (unless (= #xE5 first-byte)
        (unless (= #x0F (aref directory (+ 11 i)))
          (return i))))))

(defmacro do-files ((var) directory finally &body body)
  `(do ((,var (next-file ,directory 0) (next-file ,directory (+ 32 ,var))))
       ((null ,var)
        ,finally)
     ,@body))

(defun read-name (directory offset)
  (with-output-to-string (s)
    (loop :for i :from offset :to (+ 10 offset)
          :for octet := (aref directory i)
          :do (write-char (code-char octet) s))))

(defmacro do-file ((var start) directory finally &body body)
  (alexandria:with-gensyms (checksum order order1)
    `(do ((,checksum (checksum ,directory ,start))
          (,order -1 (1+ ,order))
          (,order1 0 (aref ,directory ,var))
          (,var ,start (- ,var 32)))
         ((or (> 0 ,var)
              (= (+ #x40 ,order)
                 ,order1))
          ,finally)
       (when (= ,checksum
                (aref ,directory (+ 13 ,var)))
         ,@body))))

(defun read-long-name (directory start)
  (let ((name ""))
    (do-file (i start) directory
             name
      (setf name
            (concatenate 'string name
                         (with-output-to-string (sub-name)
                           (flet ((add (start end)
                                    (loop :for offset :from (+ start i) :by 2 :to (+ end i)
                                          :for octet := (sys.int::ub16ref/le directory offset)
                                          :when (and (/= octet 0)
                                                     (/= octet 65535))
                                          :do (write-char (code-char octet) sub-name))))
                             (add 1 10)
                             (add 14 25)
                             (add 28 31))))))))

(defun read-file-name (directory file)
  (let ((long-name (read-long-name directory file)))
    (if (string= "" long-name)
        (let ((file-name (read-name directory file)))
          (with-output-to-string (name)
            (loop :for i :from 0 :to 7
                  :never (char= #\Space
                                (aref file-name i))
                  :do (write-char (aref file-name i) name))
            (unless (char= #\Space
                           (aref file-name 8))
              (write-char #\. name)
              (loop :for i :from 8 :to 10
                    :never (char= #\Space
                                  (aref file-name i))
                    :do (write-char (aref file-name i) name)))))
        long-name)))

(defun remove-file (directory start disk cluster-n fat32 fat)
  (do-file (i start) directory
           (progn
             ;; Remove first part of file.
             (setf (aref directory start) #xE5)
             ;; Update FAT
             (do ((i (read-first-cluster directory start)))
                 ((>= i #x0FFFFFF8) t)
               (let ((next (sys.int::ub32ref/le fat (* i 4))))
                 (setf (sys.int::ub32ref/le fat (* i 4)) 0
                       i next)))
             ;; Write to disk
             (write-fat disk fat32 fat)
             (write-file fat32 disk cluster-n fat directory))
    ;; Remove rest of file.
    (setf (aref directory i) #xE5)))

(defun next-space (directory offset)
  (do ((i offset (+ 32 i)))
      ((<= (length directory) i) nil)
    (let ((first-byte (aref directory i)))
      (when (or (zerop first-byte)
                (= #xE5 first-byte))
        (return i)))))

(defun next-n-spaces (directory n)
  (do ((i 0 (1+ i))
       (j (next-space directory 0) (next-space directory (+ 32 j)))
       (r (next-space directory 0)))
      ((= n i) r)
    (unless (= r (- j (* i 32)))
      (setf i 0
            r j))))

;; WIP
(defun create-file (host file cluster-n pathname-name pathname-type attributes)
  "Create file/directory"
  (let* ((name (concatenate 'string pathname-name "." pathname-type))
         (short-name (make-string 11 :initial-element #\Space))
         (checksum 0)
         (length (length name))
         (i (next-n-spaces file
                           (if (> length 11)
                               (1+ (ceiling
                                    (/ length 13)))
                               1))))
    (loop :for i :from 0 :to 7
          :for char :across pathname-name
          :do (setf (aref short-name i)
                    char))
    (when pathname-type
      (loop :for i :from 8 :to 10
            :for char :across pathname-type
            :do (setf (aref short-name i)
                      char)))
    ;; Check for short name collision
    (do-files (offset) file t
      (when (string= short-name (read-name file offset))
        (error "Short name ~A does alredy exist.~A~%Short name collision resolution not implemented" short-name)))
    (setf checksum
          (checksum (map 'vector #'char-code short-name) 0))
    ;; Write long name parts only if needed
    (unless (and (>= 8 (length pathname-name))
                 (>= 3 (length pathname-type)))
      (flet ((set (start end offset1)
               (loop :for offset :from (+ start i) :by 2 :to (+ start end i)
                     :for offset1 :from offset1 :by 1
                     :do (setf (sys.int::ub16ref/le file offset)
                               (cond ((= offset1 length)
                                      #x0000)
                                     ((< offset1 length)
                                      (char-code (aref name offset1)))
                                     (t #xFFFF))))))
        ;; Write long name part starting from last part
        (loop :with n := (ceiling
                          (/ length 13))
              :repeat n
              :for j :from n :by -1
              :for offset1 := (* (1- j) 13)
              :for order := (+ j #x40) :then j
              :do (progn (set 1 8 offset1)
                         (set 14 10 (+ 5 offset1))
                         (set 28 2 (+ 11 offset1))
                         (setf (aref file i) order
                               (aref file (+ i 11)) #x0F ;attributes
                               (aref file (+ i 12)) 0
                               (aref file (+ i 13)) checksum
                               (sys.int::ub16ref/le file (+ i 26)) 0
                               i (next-space file i))))))
    (multiple-value-bind (time date) (get-fat32-time)
      (let ((cluster-number (next-free-cluster (fat host))))
        (flet ((set-short-name (name file i cluster-number)
                 ;; Write short name part
                 (loop
                   :for i :from i :by 1 :to (+ i 11)
                   :for char :across name
                   :do (setf (aref file i)
                             (char-code char)))
                 (setf (aref file (+ i 11)) attributes
                       (aref file (+ i 12)) 0
                       (aref file (+ i 13)) millisecond-stamp
                       (sys.int::ub16ref/le file (+ i 14)) time
                       (sys.int::ub16ref/le file (+ i 16)) date
                       (sys.int::ub16ref/le file (+ i 18)) date
                       (sys.int::ub16ref/le file (+ i 20)) (ldb (byte 16 16) cluster-number)
                       (sys.int::ub16ref/le file (+ i 22)) time
                       (sys.int::ub16ref/le file (+ i 24)) date
                       (sys.int::ub16ref/le file (+ i 26)) (ldb (byte 16 0) cluster-number)
                       (sys.int::ub32ref/le file (+ i 28)) 0)))
          (set-short-name short-name file i cluster-number)
          ;; Make directory files . and ..
          (when (directory-p file i)
            (let ((directory (make-array (bytes-per-cluster (fat32-structure host))
                                         :area :wired :element-type '(unsigned-byte 8)
                                         :initial-element 0)))
              (set-short-name ".          " directory 0 cluster-number)
              (set-short-name "..         " directory 32 cluster-n)
              ;; Write to disk
              (write-file (fat32-structure host) (partition host) cluster-number (fat host) directory))))
        ;; Write to disk
        (write-file (fat32-structure host) (partition host) cluster-n (fat host) file)
        ;; Update fat
        (setf (sys.int::ub32ref/le (fat host) (* cluster-number 4))
              #x0FFFFFFF)
        (write-fat (partition host)
                   (fat32-structure host)
                   (fat host))
        ;; Return cluster-number
        cluster-number))))

;; WIP
;; (defun rename-file (cluster start disk sector fat32 name)
;;   (error "WIP"))

;;; Host integration

(defclass fat32-host ()
  ((%name :initarg :name
          :reader host-name)
   (%lock :initarg :lock
          :reader fat32-host-lock)
   (partition :initarg :partition
              :reader partition)
   (fat32-structure :initarg :fat32-structure
                    :reader fat32-structure)
   (fat32-info :initarg :fat32-info
               :reader fat32-info)
   (fat :initarg :fat
        :reader fat))
  (:default-initargs :lock (mezzano.supervisor:make-mutex "Local File Host lock")))

(defmethod host-default-device ((host fat32-host))
  nil)

(defun parse-simple-file-path (host namestring)
  (let ((start 0)
        (end (length namestring))
        (directory '())
        (name nil)
        (type nil))
    (when (eql start end)
      (return-from parse-simple-file-path (make-pathname :host host)))
    (cond ((eql (char namestring start) #\>)
           (push :absolute directory)
           (incf start))
          (t (push :relative directory)))
    ;; Last element is the name.
    (do* ((x (explode #\> namestring start end) (cdr x)))
         ((null (cdr x))
          (let* ((name-element (car x))
                 (end (length name-element)))
            (unless (zerop (length name-element))
              ;; Find the last dot.
              (let ((dot-position (position #\. name-element :from-end t)))
                (cond ((and dot-position (not (zerop dot-position)))
                       (setf type (subseq name-element (1+ dot-position) end))
                       (setf name (subseq name-element 0 dot-position)))
                      (t (setf name (subseq name-element 0 end))))))))
      (let ((dir (car x)))
        (cond ((or (string= "" dir)
                   (string= "." dir)))
              ((string= ".." dir)
               (push :up directory))
              ((string= "*" dir)
               (push :wild directory))
              ((string= "**" dir)
               (push :wild-inferiors directory))
              (t (push dir directory)))))
    (when (string= name "*") (setf name :wild))
    (when (string= type "*") (setf type :wild))
    (make-pathname :host host
                   :directory (nreverse directory)
                   :name name
                   :type type
                   :version :newest)))

(defmethod parse-namestring-using-host ((host fat32-host) namestring junk-allowed)
  (assert (not junk-allowed) (junk-allowed) "Junk-allowed not implemented yet")
  (parse-simple-file-path host namestring))

(defmethod unparse-pathname (pathname (host fat32-host))
  (when (pathname-device pathname)
    (error 'no-namestring-error
           :pathname pathname
           :format-control "Pathname has a device component"))
  (let ((dir (pathname-directory pathname))
        (name (pathname-name pathname))
        (type (pathname-type pathname)))
    (with-output-to-string (s)
      (when (eql (first dir) :absolute)
        (write-char #\> s))
      (dolist (sub-dir (rest dir))
        (cond
          ((stringp sub-dir) (write-string sub-dir s))
          ((eql sub-dir :up) (write-string ".." s))
          ((eql sub-dir :wild) (write-char #\* s))
          ((eql sub-dir :wild-inferiors) (write-string "**" s))
          (t
           (error 'no-namestring-error
                  :pathname pathname
                  :format-control "Invalid directory component ~S."
                  :format-arguments (list sub-dir))))
        (write-char #\> s))
      (if (eql name :wild)
          (write-char #\* s)
          (write-string name s))
      (when type
        (write-char #\. s)
        (if (eql type :wild)
            (write-char #\* s)
            (write-string type s)))
      s)))

(defclass fat32-file-stream (sys.gray:fundamental-binary-input-stream
                             sys.gray:fundamental-binary-output-stream
                             file-stream)
  ((path :initarg :path :reader path) ;<
   (pathname :initarg :pathname :reader file-stream-pathname)
   (host :initarg :host :reader host)
   (direction :initarg :direction :reader direction)
   ;; Read buffer.
   (read-buffer :initarg :read-buffer
                :accessor read-buffer)
   ;; File position where the buffer data starts.
   (read-buffer-position :initarg :read-buffer-position
                         :initform 0
                         :accessor read-buffer-position)
   ;; Current offset into the buffer.
   (buffer-offset :initarg :buffer-offset
                  :accessor buffer-offset)
   ;; File size
   (read-buffer-size :initarg :read-buffer-size
                     :initform 0
                     :accessor read-buffer-size)
   ;; Write buffer.
   (write-buffer :initarg :write-buffer
                 :initform nil
                 :accessor write-buffer) ;<
   (write-buffer-position :initarg :write-buffer-position
                          :initform 0
                          :accessor write-buffer-position) ;<
   (abort-action :initarg :abort-action :accessor abort-action)))

(defclass fat32-file-character-stream (sys.gray:fundamental-character-input-stream
                                       sys.gray:fundamental-character-output-stream
                                       fat32-file-stream
                                       sys.gray:unread-char-mixin)
  ())

(defmacro with-fat32-host-locked ((host) &body body)
  `(mezzano.supervisor:with-mutex ((fat32-host-lock ,host))
     ,@body))

(defun file-name (pathname)
  "Take pathname and return file name name."
  (unless (or (eql :wild (pathname-name pathname))
              (eql :wild (pathname-type pathname)))
    (if (pathname-type pathname)
        (concatenate 'string (pathname-name pathname) "." (pathname-type pathname))
        (pathname-name pathname))))

(defun find-file (host pathname)
  (loop :with fat32 := (fat32-structure host)
        :with disk := (partition host)
        :with file-name := (file-name pathname)
        :with cluster-n := (fat32-root-cluster fat32)
        :with file-data := (read-file fat32 disk (fat32-root-cluster fat32) (fat host))
        :for directory :in (rest (pathname-directory pathname))
        :do (do-files (start) file-data
                      (error 'simple-file-error
                             :pathname pathname
                             :format-control "Directory ~A not found. ~S"
                             :format-arguments (list directory pathname))
              (when (string= directory (read-file-name file-data start))
                (setf cluster-n (read-first-cluster file-data start)
                      file-data (read-file fat32 disk (read-first-cluster file-data start) (fat host)))))
        :finally (if (null file-name)
                     (return-from find-file (values file-data cluster-n))
                     (do-files (start) file-data
                               (values file-data cluster-n)
                       (when (string= file-name (read-file-name file-data start))
                         (return-from find-file (values file-data cluster-n start)))))))

;; WIP
(defmethod open-using-host ((host fat32-host) pathname
                            &key direction element-type if-exists if-does-not-exist external-format)
  (with-fat32-host-locked (host)
    (let ((buffer nil)
          (read-buffer-position 0)
          (buffer-offset 0)
          (read-buffer-size 0)
          (created-file nil)
          (abort-action nil))
      (multiple-value-bind (file-data cluster-n start) (find-file host pathname)
        (declare (ignore cluster-n))
        (if start
            (setf buffer (read-file (fat32-structure host)
                                    (partition host)
                                    (read-first-cluster file-data start)
                                    (fat host))
                  read-buffer-position (read-first-cluster file-data start)
                  read-buffer-size (read-file-size file-data start))
            (ecase if-does-not-exist
              (:error (error 'simple-file-error
                             :pathname pathname
                             :format-control "File ~A does not exist. ~S"
                             :format-arguments (list pathname (file-name pathname))))
              ;; TODO Implement abort-action :delete
              (:create (setf created-file t
                             abort-action :delete)
               (let* ((namestring (namestring pathname)))
                 (loop :for i from (- (length namestring) 2) :downto 0
                       :when (char= #\> (char namestring i))
                       :do (multiple-value-bind (file-data cluster-n)
                               (find-file host (pathname (subseq namestring 0 (1+ i))))
                             (let ((cluster-number
                                     (if (file-name pathname)
                                         (first-sector-of-cluster (fat32-structure host)
                                                                  (create-file host file-data cluster-n
                                                                               (pathname-name pathname)
                                                                               (pathname-type pathname)
                                                                               (ash 1 +attribute-archive+)))
                                         (first-sector-of-cluster (fat32-structure host)
                                                                  (create-file host file-data cluster-n
                                                                               (subseq namestring
                                                                                       (1+ i)
                                                                                       (1- (length namestring)))
                                                                               nil
                                                                               (ash 1 +attribute-directory+))))))
                               (setf buffer (make-array (* (fat32-sectors-per-cluster (fat32-structure host))
                                                           (fat32-bytes-per-sector (fat32-structure host)))
                                                        :initial-element 0)
                                     read-buffer-position cluster-number
                                     read-buffer-size 0)))))))))
      (when (and (not created-file) (member direction '(:output :io)))
        (ecase if-exists
          (:error (error 'simple-file-error
                         :pathname pathname
                         :format-control "File ~A exists."
                         :format-arguments (list pathname)))
          ((:new-version
            :rename
            :rename-and-delete)
           (when t
             (error 'simple-file-error
                    :pathname pathname
                    :format-control "Could not rename ~S."
                    :format-arguments (list pathname)))
           (when t
             (error 'simple-file-error
                    :pathname pathname
                    :format-control "Could not supersede ~S."
                    :format-arguments (list pathname)))
           (when created-file
             (error "Cannot create ~A. ~S" pathname)))
          (:supersede
           (setf abort-action :delete)
           (when nil
             (error 'simple-file-error
                    :pathname pathname
                    :format-control "Could not supersede ~S."
                    :format-arguments (list pathname)))
           (unless created-file
             (error "Cannot create ~A. ~S" pathname)))
          ((:overwrite) t)
          ((:append)
           (setf buffer-offset read-buffer-size))
          ((nil) (return-from open-using-host nil))))
      (let ((stream (cond ((or (eql element-type :default)
                               (subtypep element-type 'character))
                           (assert (member external-format '(:default :utf-8))
                                   (external-format))
                           (make-instance 'fat32-file-character-stream
                                          :pathname pathname
                                          :host host
                                          :direction direction
                                          :read-buffer buffer
                                          :read-buffer-position read-buffer-position
                                          :buffer-offset buffer-offset
                                          :read-buffer-size read-buffer-size))
                          ((and (subtypep element-type '(unsigned-byte 8))
                                (subtypep '(unsigned-byte 8) element-type))
                           (assert (eql external-format :default) (external-format))
                           (make-instance 'fat32-file-stream
                                          :pathname pathname
                                          :host host
                                          :direction direction
                                          :read-buffer buffer
                                          :read-buffer-position read-buffer-position
                                          :buffer-offset buffer-offset
                                          :read-buffer-size read-buffer-size))
                          (t (error "Unsupported element-type ~S." element-type)))))
        stream))))

(defmethod directory-using-host ((host fat32-host) pathname &key)
  (let ((file-data (find-file host pathname)))
    (let ((stack '())
          (path (unparse-pathname-directory pathname host)))
      (do-files (file) file-data
                t
        (push
         (parse-simple-file-path host
                                 (format nil
                                         (if (file-p file-data file)
                                             "~a~a"
                                             "~a~a>")
                                         path
                                         (read-file-name file-data file)))
         stack))
      (return-from directory-using-host stack))))

;; WIP
(defmethod ensure-directories-exist-using-host ((host fat32-host) pathname &key verbose)
  (error "Feature not implemented: ~a" 'ensure-directories-exist-using-host))

;; WIP
(defmethod rename-file-using-host ((host fat32-host) source dest)
  (error "Feature not implemented: ~a" 'rename-file-using-host))

(defmethod file-write-date-using-host ((host fat32-host) path)
  (multiple-value-bind (file cluster-n metadata-offset) (find-file host path)
    (declare (ignore cluster-n))
    (assert metadata-offset (metadata-offset) "File not found. ~s" path)
    (let ((time (sys.int::ub16ref/le file (+ metadata-offset 22)))
          (date (sys.int::ub16ref/le file (+ metadata-offset 24))))
      (encode-universal-time (ash (ldb (byte 5 0) time) 1)
                             (ldb (byte 6 5) time)
                             (ldb (byte 5 11) time)
                             (ldb (byte 5 0) date)
                             (ldb (byte 4 5) date)
                             (+ 1980 (ldb (byte 7 9) date))))))

(defmethod delete-file-using-host ((host fat32-host) path &key)
  (let* ((disk (partition host))
         (fat32 (fat32-structure host))
         (fat (fat host)))
    (multiple-value-bind (directory cluster-n start) (find-file host path)
      (assert start (start) "File/directory not found. ~s" path)
      (remove-file directory start disk cluster-n fat32 fat))))

(defmethod expunge-directory-using-host ((host fat32-host) path &key)
  (declare (ignore host path))
  t)

(defmethod stream-truename ((stream fat32-file-stream))
  (file-stream-pathname stream))

(defmethod sys.gray:stream-element-type ((stream fat32-file-stream))
  '(unsigned-byte 8))

(defmethod sys.gray:stream-element-type ((stream fat32-file-character-stream))
  'character)

;; WIP
;; TODO resize to files bigger than 1 cluster
(defmethod sys.gray:stream-write-byte ((stream fat32-file-stream) byte)
  (assert (member (direction stream) '(:output :io)))
  (when (> (buffer-offset stream)
           (read-buffer-size stream))
    (setf (read-buffer-size stream)
          (buffer-offset stream)))
  (setf (aref (read-buffer stream)
              (buffer-offset stream))
        byte)
  (incf (buffer-offset stream)))

(defmethod sys.gray:stream-read-byte ((stream fat32-file-stream))
  (assert (member (direction stream) '(:input :io)))
  (let ((char (aref (read-buffer stream)
                    (buffer-offset stream))))
    (incf (buffer-offset stream))
    (if (<= (read-buffer-size stream)
            (buffer-offset stream))
        :eof
        char)))

(defmethod sys.gray:stream-read-sequence ((stream fat32-file-stream) sequence &optional (start 0) end)
  (assert (member (direction stream) '(:input :io)))
  (unless end (setf end (length sequence)))
  (let ((end2 (min end (read-buffer-size stream))))
    (replace sequence (read-buffer stream) :start1 start :end1 end :start2 0 :end2 end2)
    end2))

;; WIP
;; TODO resize to files bigger than 1 cluster
(defmethod sys.gray:stream-write-char ((stream fat32-file-character-stream) char)
  (assert (member (direction stream) '(:output :io)))
  (when (> (buffer-offset stream)
           (read-buffer-size stream))
    (setf (read-buffer-size stream)
          (buffer-offset stream)))
  (setf (aref (read-buffer stream)
              (buffer-offset stream))
        (char-code char))
  (incf (buffer-offset stream)))

(defmethod sys.gray:stream-read-char ((stream fat32-file-character-stream))
  (assert (member (direction stream) '(:input :io)))
  (let ((char (aref (read-buffer stream)
                    (buffer-offset stream))))
    (incf (buffer-offset stream))
    (if (<= (read-buffer-size stream)
            (buffer-offset stream))
        :eof
        (code-char char))))

(defmethod sys.gray:stream-read-sequence ((stream fat32-file-character-stream) sequence &optional (start 0) end)
  (assert (member (direction stream) '(:input :io)))
  (unless end (setf end (length sequence)))
  (let ((end2 (min end (read-buffer-size stream))))
    (loop :for n1 :from start :to (1- end)
          :for n2 :to (1- end2)
          :do (setf (aref sequence n1)
                    (code-char (aref (read-buffer stream) n2))))
    end2))

(defmethod sys.gray:stream-file-position ((stream fat32-file-stream) &optional (position-spec nil position-specp))
  (cond (position-specp
         (setf (buffer-offset stream) (if (eql position-spec :end)
                                          (read-buffer-size stream)
                                          position-spec)))
        (t (buffer-offset stream))))

(defmethod sys.gray:stream-file-length ((stream fat32-file-stream))
  (read-buffer-size stream))

;; WIP
(defmethod close ((stream fat32-file-stream) &key abort)
  (cond ((not abort)
         (let* ((host (host stream))
                (file-length (read-buffer-size stream)))
           (multiple-value-bind (directory cluster-n offset)
               (find-file host (file-stream-pathname stream))
             (multiple-value-bind (time date) (get-fat32-time)
               (when (member (direction stream) '(:output :io))
                 (let ((host (host stream)))
                   (write-file (fat32-structure host)
                               (partition host)
                               (read-buffer-position stream)
                               (fat host)
                               (read-buffer stream)))
                 ;; Set file size
                 (setf (sys.int::ub16ref/le directory (+ offset 22)) time
                       (sys.int::ub16ref/le directory (+ offset 24)) date
                       (sys.int::ub32ref/le directory (+ 28 offset)) file-length))
               ;; Set last accsess date
               (setf (sys.int::ub16ref/le directory (+ offset 18)) date))
             ;; Write to disk new metadata
             (write-file (fat32-structure host) (partition host) cluster-n (fat host) directory))))
        (t (error "Aborted close not suported")))
  t)

;;; testing

;; Mount partition
;; (let* ((disk-name "FAT32")
;;        (disk (nth 3 (mezzano.supervisor:all-disks)))
;;        (fat32 (read-fat32-structure disk))
;;        (fat32-info (read-fat32-info-structure disk fat32))
;;        (fat (read-fat disk fat32))
;;        (instance (make-instance 'fat32-host
;;                                 :name disk-name
;;                                 :partition disk
;;                                 :fat32-structure fat32
;;                                 :fat32-info fat32-info
;;                                 :fat fat)))
;;   (setf (mezzano.file-system:find-host disk-name)
;;         instance))

;; (let ((path #P"FAT32:>file5"))
;;   ;; Write to some file
;;   (time
;;    (with-open-file (file path :direction :output :if-exists :overwrite)
;;      (loop for i to (read-buffer-size file)
;;            do (write-byte (ldb (byte 8 0) i) file))))
;;   ;; Read some file
;;   (time
;;    (with-open-file (file path)
;;      (loop for char = (read-char file nil nil)
;;            while char do (write-char char)))))
